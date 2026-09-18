--[[
	RoomManager (lobby-only)

	포탈 인스턴스마다 독립적인 파티 상태 머신을 운영한다(포탈별 PortalState):
		Idle → PopupOpen(leader=A) → Recruiting(20s) → Teleporting(즉시 ReserveServer 후 플레이어별 TeleportAsync, 코호트=성공 인원만) → Idle
	한 포탈의 파티가 Idle로 돌아오면 그 포탈은 즉시 새 파티를 다시 받을 수 있다(다른 포탈과 무관).

	- ReserveServer 실패 시 파티원 전원을 해당 stage/diff WarpPoint 로 이동 후 Idle.
	- 플레이어별 TeleportAsync: 성공한 유저만 코호트(로비 이탈 감지), 실패한 유저만 WarpPoint 로 이동. 전원 실패 시 Idle.
	- 코호트 전원 PlayerRemoving 후 Idle, 최대 10s 타임아웃. Teleporting 중 LockWall/비파티원 워프는 기존과 동일(그 포탈만).

	- 포털 Touched 시 PortalHandler가 RoomManager.tryStartParty(player, portal, stage, diff, joinCnt) 호출.
	- PopupOpen 이고 pending 과 동일 stage/diff 포탈에 비리더가 올라서면 PortalHandler가 해당 포탈 WarpPoint로 이동 (tryStartParty 미호출).
	- 리더가 (자신이 PopupOpen 중인) 다른 포탈로 이동하면 이전 포탈은 Idle 로 정리하고 새 포탈에서 PopupOpen.
	- 플레이어는 동시에 하나의 방(userIdToRoomId)에만 속함 — 이미 Recruiting/Teleporting 중이면 다른 포탈에서 새 파티를 시작할 수 없음.
	- Idle이면 leader 지정 + OpenPartyPopupEvent 송신.
	- Recruiting이면 같은 stage/diff에 한해 즉시 합류, 정원 충족 시 즉시 Teleporting.
	- 그 외 상태/조건은 거절.
	- 클라 Cancel/Create는 RemoteEvent로 처리(서버가 leaderPortal 로 어느 포탈인지 조회).
	- 모든 상태 전이는 포탈 단위로 LobbyPartyStateEvent(payload.portal 포함)를 ALL FireClient.
]]

local RoomManager = {}

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlaceIds = require(Shared.Config.PlaceIds)
local DifficultyConfig = require(Shared.Config.DifficultyConfig)
local PortalLobbyWarp = require(Shared.Utils.PortalLobbyWarp)
local StringHelper = require(Shared.Helpers.StringHelper)

local LobbyPhysicsSetup = require(script.Parent.LobbyPhysicsSetup)

export type Difficulty = number

export type Room = {
	id: string,
	portal: Instance,
	stageNumber: number,
	difficulty: Difficulty,
	capacity: number,
	memberUserIds: { number },
	createdAt: number,
}

local STATE_IDLE = "Idle"
local STATE_POPUP = "PopupOpen"
local STATE_RECRUITING = "Recruiting"
local STATE_TELEPORTING = "Teleporting"

RoomManager.Difficulty = {
	Easy = DifficultyConfig.Easy,
	Normal = DifficultyConfig.Normal,
	Hard = DifficultyConfig.Hard,
}

local LOCALE = "kr"

function RoomManager.getDifficultyLabel(difficulty: Difficulty): string
	local key = DifficultyConfig.labelKeys[difficulty]
	if key then
		return StringHelper.get(key, LOCALE)
	end
	return tostring(difficulty)
end

local CREATE_PARTY_EVENT_NAME = "CreatePartyRequestEvent"
local CANCEL_PARTY_EVENT_NAME = "CancelPartyRequestEvent"
local LEAVE_ROOM_EVENT_NAME = "LeaveRoomRequestEvent"
local OPEN_PARTY_POPUP_EVENT_NAME = "OpenPartyPopupEvent"
local LOBBY_PARTY_STATE_EVENT_NAME = "LobbyPartyStateEvent"

RoomManager.CREATE_PARTY_EVENT_NAME = CREATE_PARTY_EVENT_NAME
RoomManager.CANCEL_PARTY_EVENT_NAME = CANCEL_PARTY_EVENT_NAME
RoomManager.LEAVE_ROOM_EVENT_NAME = LEAVE_ROOM_EVENT_NAME
RoomManager.OPEN_PARTY_POPUP_EVENT_NAME = OPEN_PARTY_POPUP_EVENT_NAME
RoomManager.LOBBY_PARTY_STATE_EVENT_NAME = LOBBY_PARTY_STATE_EVENT_NAME

local TOUCH_DEBOUNCE_SEC = 0.5
local RECRUIT_TIMEOUT_SEC = 20
local TELEPORT_IDLE_TIMEOUT_SEC = 30

-- --- 상태 ---

export type PortalState = {
	lobbyState: string,
	leaderUserId: number?,
	currentRoomId: string?,
	pendingStageNumber: number?,
	pendingDifficulty: Difficulty?,
	pendingJoinCnt: number?,
	recruitDeadline: number?,
	teleportDeadline: number?,
	recruitTimerSerial: number,
	teleportSerial: number,
	--- TeleportAsync 성공 시점에 넣은 플레이어 userId 목록(로비 이탈 감지용).
	teleportCohortUserIds: { number }?,
	--- Recruiting 진입 시 미리 ReserveServer 로 예약 서버를 준비(스핀업 선행).
	reservedRoomId: string?,
	reservedPlaceId: number?,
	reservedAccessCode: string?,
}

local rooms: { [string]: Room } = {}
local userIdToRoomId: { [number]: string } = {}
local roomIdSerial = 0

function RoomManager.isPlayerInRoom(userId: number): boolean
	return userIdToRoomId[userId] ~= nil
end

-- PvpRoomManager 순환 참조 방지: 호출 시점에 lazy require
local function isInPvpMatch(userId: number): boolean
	local ok, PvpRoomManager = pcall(function()
		return require(script.Parent.PvpRoomManager)
	end)
	if not ok or typeof(PvpRoomManager) ~= "table" then
		return false
	end
	local fn = (PvpRoomManager :: any).isPlayerInMatch
	if typeof(fn) ~= "function" then
		return false
	end
	return fn(userId) == true
end


--- 포탈 인스턴스 -> 그 포탈의 파티 상태. 포탈마다 완전히 독립적으로 운영된다.
local portalStates: { [Instance]: PortalState } = {}
--- PopupOpen 리더가 다른 포탈로 이동했을 때 이전 포탈을 정리하기 위한 역참조.
local leaderPortal: { [number]: Instance } = {}
--- 포탈별 터치 디바운스(한 포탈의 지터가 다른 포탈에 영향을 주지 않도록 포탈 단위로 분리).
local lastTouchClockByPortal: { [Instance]: { [number]: number } } = {}

local openPartyPopupEvent: RemoteEvent? = nil
local lobbyPartyStateEvent: RemoteEvent? = nil

-- --- 유틸 ---

local function newPortalState(): PortalState
	return {
		lobbyState = STATE_IDLE,
		leaderUserId = nil,
		currentRoomId = nil,
		pendingStageNumber = nil,
		pendingDifficulty = nil,
		pendingJoinCnt = nil,
		recruitDeadline = nil,
		teleportDeadline = nil,
		recruitTimerSerial = 0,
		teleportSerial = 0,
		teleportCohortUserIds = nil,
		reservedRoomId = nil,
		reservedPlaceId = nil,
		reservedAccessCode = nil,
	}
end

local function getOrCreatePortalState(portal: Instance): PortalState
	local ps = portalStates[portal]
	if not ps then
		ps = newPortalState()
		portalStates[portal] = ps
	end
	return ps
end

local function generateRoomId(stageNumber: number, difficulty: Difficulty): string
	roomIdSerial += 1
	return string.format("S%d-D%d-#%d", stageNumber, difficulty, roomIdSerial)
end

local function getStagePlaceId(stageNumber: number): number?
	local placeId = PlaceIds.Stages[stageNumber]
	if not placeId or placeId == 0 then
		return nil
	end
	return placeId
end

local function isValidDifficulty(difficulty: Difficulty): boolean
	return DifficultyConfig.labelKeys[difficulty] ~= nil
end

local function indexOf(list: { number }, value: number): number?
	for i, v in ipairs(list) do
		if v == value then
			return i
		end
	end
	return nil
end

local function buildTeleportData(room: Room)
	return {
		stageNumber = room.stageNumber,
		difficulty = room.difficulty,
		roomId = room.id,
		capacity = room.capacity,
	}
end

local function getCurrentRoom(ps: PortalState): Room?
	if not ps.currentRoomId then
		return nil
	end
	return rooms[ps.currentRoomId]
end

local function buildStatePayload(portal: Instance, ps: PortalState)
	local room = getCurrentRoom(ps)

	-- PopupOpen 동안에는 아직 room이 없어 stage/diff을 pending 값으로 채워서 보낸다.
	local stageOut = room and room.stageNumber or nil
	local diffOut = room and room.difficulty or nil
	if ps.lobbyState == STATE_POPUP then
		stageOut = ps.pendingStageNumber
		diffOut = ps.pendingDifficulty
	end

	local memberIdsList: { number } = {}
	if room then
		for _, uid in ipairs(room.memberUserIds) do
			table.insert(memberIdsList, uid)
		end
	end
	local memberIds: { number }? = if room then memberIdsList else nil

	return {
		portal = portal,
		state = ps.lobbyState,
		stageNumber = stageOut,
		difficulty = diffOut,
		capacity = room and room.capacity or nil,
		current = room and #room.memberUserIds or nil,
		memberUserIds = memberIds,
		leaderUserId = ps.leaderUserId,
		recruitDeadline = ps.recruitDeadline,
		teleportDeadline = ps.teleportDeadline,
		recruitTimeoutSec = (ps.lobbyState == STATE_RECRUITING) and RECRUIT_TIMEOUT_SEC or nil,
		teleportDelaySec = (ps.lobbyState == STATE_TELEPORTING) and TELEPORT_IDLE_TIMEOUT_SEC or nil,
	}
end

local function broadcastState(portal: Instance, ps: PortalState)
	if lobbyPartyStateEvent then
		lobbyPartyStateEvent:FireAllClients(buildStatePayload(portal, ps))
	end
	local wallBlocksEveryone = ps.lobbyState == STATE_POPUP or ps.lobbyState == STATE_TELEPORTING
	LobbyPhysicsSetup.setPortalLockWallBlocksEveryone(portal, wallBlocksEveryone)
end

local function clearRoom(room: Room?)
	if not room then
		return
	end
	for _, uid in ipairs(room.memberUserIds) do
		userIdToRoomId[uid] = nil
	end
	rooms[room.id] = nil
end

-- --- 상태 전이 ---

local transitionToTeleporting

local function clearReservedServer(ps: PortalState)
	ps.reservedRoomId = nil
	ps.reservedPlaceId = nil
	ps.reservedAccessCode = nil
end

--- Recruiting 진입 시 목적지 예약 서버를 미리 확보(스핀업 선행).
--- 모집 대기(최대 RECRUIT_TIMEOUT_SEC) 동안 서버가 뜨므로 텔레포트 시점 대기가 줄어든다.
local function preloadReservedServerForRoom(room: Room)
	local placeId = getStagePlaceId(room.stageNumber)
	if not placeId then
		return
	end
	local roomId = room.id
	local portal = room.portal
	task.spawn(function()
		local code: string?
		local ok, err = pcall(function()
			code = TeleportService:ReserveServer(placeId)
		end)
		-- 예약 완료 시점에도 같은 방이 모집/텔레포트 중일 때만 캐시(방이 바뀌었으면 폐기).
		if not ok or not code then
			warn("[RoomManager] 사전 ReserveServer 실패(텔레포트 시 재시도):", err)
			return
		end
		local ps = portalStates[portal]
		if not ps or ps.currentRoomId ~= roomId then
			return
		end
		ps.reservedRoomId = roomId
		ps.reservedPlaceId = placeId
		ps.reservedAccessCode = code
		print("[RoomManager] 예약 서버 사전 확보 완료 room=", roomId)
	end)
end

local function transitionToIdle(portal: Instance, ps: PortalState)
	if ps.leaderUserId and leaderPortal[ps.leaderUserId] == portal then
		leaderPortal[ps.leaderUserId] = nil
	end
	ps.teleportCohortUserIds = nil
	clearReservedServer(ps)
	local room = getCurrentRoom(ps)
	clearRoom(room)
	ps.lobbyState = STATE_IDLE
	ps.leaderUserId = nil
	ps.currentRoomId = nil
	ps.pendingStageNumber = nil
	ps.pendingDifficulty = nil
	ps.pendingJoinCnt = nil
	ps.recruitDeadline = nil
	ps.teleportDeadline = nil
	ps.recruitTimerSerial += 1
	ps.teleportSerial += 1
	broadcastState(portal, ps)
	print("[RoomManager] state → Idle", portal:GetFullName())
end

local function tryTransitionIdleAfterTeleportIfAllGone(portal: Instance, ps: PortalState)
	if ps.lobbyState ~= STATE_TELEPORTING then
		return
	end
	if not ps.teleportCohortUserIds then
		return
	end
	for _, uid in ipairs(ps.teleportCohortUserIds) do
		if Players:GetPlayerByUserId(uid) ~= nil then
			return
		end
	end
	print("[RoomManager] Teleport 코호트 전원 로비 이탈 → Idle", portal:GetFullName())
	transitionToIdle(portal, ps)
end

local function createRoomInternal(portal: Instance, stageNumber: number, difficulty: Difficulty, capacity: number): Room?
	if typeof(stageNumber) ~= "number" or stageNumber < 1 then
		return nil
	end
	if not isValidDifficulty(difficulty) then
		return nil
	end
	if typeof(capacity) ~= "number" or capacity < 1 then
		return nil
	end
	if not getStagePlaceId(stageNumber) then
		return nil
	end

	local id = generateRoomId(stageNumber, difficulty)
	local room: Room = {
		id = id,
		portal = portal,
		stageNumber = stageNumber,
		difficulty = difficulty,
		capacity = capacity,
		memberUserIds = {},
		createdAt = os.clock(),
	}
	rooms[id] = room
	return room
end

local function addMemberToRoom(room: Room, player: Player): boolean
	if userIdToRoomId[player.UserId] then
		return false
	end
	if #room.memberUserIds >= room.capacity then
		return false
	end
	table.insert(room.memberUserIds, player.UserId)
	userIdToRoomId[player.UserId] = room.id
	print("[RoomManager]", player.Name, "→", room.id, string.format("(%d/%d)", #room.memberUserIds, room.capacity))
	return true
end

local function collectRoomPlayers(room: Room): { Player }
	local list: { Player } = {}
	for _, uid in ipairs(room.memberUserIds) do
		local p = Players:GetPlayerByUserId(uid)
		if p then
			table.insert(list, p)
		end
	end
	return list
end

--- (사전)예약 서버 확보 후 배치 TeleportAsync. Reserve 실패 시 전원 WarpPoint 후 Idle.
--- 배치 실패 시에만 개별 재시도. 텔레포트 성공 userId 만 코호트(실패자는 WarpPoint 로 이동, 로비 잔류).
local function finalDispatchAndIdle(portal: Instance, ps: PortalState, teleportOpSerial: number)
	local room = getCurrentRoom(ps)
	if not room then
		transitionToIdle(portal, ps)
		return
	end
	local placeId = getStagePlaceId(room.stageNumber)
	if not placeId then
		warn("[RoomManager] dispatch 실패: PlaceId 없음 stage=", room.stageNumber)
		transitionToIdle(portal, ps)
		return
	end
	local players = collectRoomPlayers(room)
	if #players == 0 then
		warn("[RoomManager] dispatch 시점 인원 0:", room.id)
		transitionToIdle(portal, ps)
		return
	end

	local stageN = room.stageNumber
	local diffN = room.difficulty

	local code: string? = nil
	-- 사전 확보한 예약 서버 코드가 이 방/플레이스에 유효하면 재사용(스핀업 대기 생략).
	if ps.reservedAccessCode and ps.reservedRoomId == room.id and ps.reservedPlaceId == placeId then
		code = ps.reservedAccessCode
		print("[RoomManager] 사전 확보 예약 서버 재사용 room=", room.id)
	else
		local okReserve, errReserve = pcall(function()
			code = TeleportService:ReserveServer(placeId)
		end)
		if not okReserve or not code then
			warn("[RoomManager] ReserveServer 실패:", errReserve)
			for _, p in ipairs(players) do
				if p.Parent then
					PortalLobbyWarp.warpPlayerToStageDifficultyWarpPoint(p, stageN, diffN)
				end
			end
			transitionToIdle(portal, ps)
			return
		end
	end

	-- 이 코드는 이번 dispatch 에 소비되므로 캐시를 비워 다음 방이 재사용하지 않게 한다.
	clearReservedServer(ps)

	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = code
	options:SetTeleportData(buildTeleportData(room))

	local livePlayers: { Player } = {}
	for _, p in ipairs(players) do
		if p and p.Parent then
			table.insert(livePlayers, p)
		end
	end

	-- 배치 텔레포트: 예약 서버로 파티 전원을 한 번에 요청(순차 yield 제거).
	local cohort: { number } = {}
	local okBatch, errBatch = pcall(function()
		TeleportService:TeleportAsync(placeId, livePlayers, options)
	end)
	if okBatch then
		for _, p in ipairs(livePlayers) do
			table.insert(cohort, p.UserId)
		end
	else
		warn("[RoomManager] TeleportAsync 배치 실패 → 개별 재시도:", errBatch)
		-- 배치 실패 시에만 개별 재시도(실패자만 WarpPoint 로 이동).
		for _, p in ipairs(livePlayers) do
			if p and p.Parent then
				local okT, errTeleport = pcall(function()
					TeleportService:TeleportAsync(placeId, { p }, options)
				end)
				if okT then
					table.insert(cohort, p.UserId)
				else
					warn("[RoomManager] TeleportAsync 실패 (단일):", p.Name, errTeleport)
					PortalLobbyWarp.warpPlayerToStageDifficultyWarpPoint(p, stageN, diffN)
				end
			end
		end
	end

	if #cohort == 0 then
		warn("[RoomManager] TeleportAsync 전원 실패 → Idle")
		transitionToIdle(portal, ps)
		return
	end

	ps.teleportCohortUserIds = cohort

	print(
		string.format(
			"[RoomManager] 방 텔레포트 요청 완료 (성공 %d/%d, room=%s)",
			#cohort,
			#players,
			room.id
		)
	)
	tryTransitionIdleAfterTeleportIfAllGone(portal, ps)

	task.delay(TELEPORT_IDLE_TIMEOUT_SEC, function()
		if teleportOpSerial ~= ps.teleportSerial then
			return
		end
		if ps.lobbyState ~= STATE_TELEPORTING then
			return
		end
		print(string.format("[RoomManager] Teleport Idle 타임아웃(%ds) → Idle", TELEPORT_IDLE_TIMEOUT_SEC))
		transitionToIdle(portal, ps)
	end)
end

transitionToTeleporting = function(portal: Instance, ps: PortalState)
	if ps.lobbyState == STATE_TELEPORTING then
		return
	end
	if not getCurrentRoom(ps) then
		return
	end
	ps.recruitTimerSerial += 1
	ps.recruitDeadline = nil
	ps.lobbyState = STATE_TELEPORTING
	ps.teleportDeadline = workspace:GetServerTimeNow() + TELEPORT_IDLE_TIMEOUT_SEC
	print(
		string.format(
			"[RoomManager] state → Teleporting (%s, 즉시 ReserveServer + 배치 TeleportAsync, 코호트 이탈 또는 %ds 타임아웃 후 Idle)",
			portal:GetFullName(),
			TELEPORT_IDLE_TIMEOUT_SEC
		)
	)

	-- 클라 UI/물리 갱신은 텔레포트 요청과 병렬로 처리(요청 시작을 지연시키지 않도록 defer).
	task.defer(function()
		broadcastState(portal, ps)
	end)

	ps.teleportSerial += 1
	local s = ps.teleportSerial
	finalDispatchAndIdle(portal, ps, s)
end

local function startRecruitTimeout(portal: Instance, ps: PortalState)
	ps.recruitTimerSerial += 1
	local s = ps.recruitTimerSerial
	task.delay(RECRUIT_TIMEOUT_SEC, function()
		if s ~= ps.recruitTimerSerial or ps.lobbyState ~= STATE_RECRUITING then
			return
		end
		print("[RoomManager] 모집 시간 만료 → Teleporting", portal:GetFullName())
		transitionToTeleporting(portal, ps)
	end)
end

-- --- 외부에서 호출되는 진입점 ---

--- 포털 Touched 시 호출. Idle이면 PopupOpen, Recruiting이면 같은 stage/diff에 즉시 합류.
--- portal: 터치된 포탈 인스턴스(포탈마다 독립적인 파티 상태를 가짐).
--- joinCnt: 포털 `JoinCnt` 특성(1~5). 팝업에서 선택 가능한 최대 정원.
function RoomManager.tryStartParty(
	player: Player,
	portal: Instance,
	stageNumber: number,
	difficulty: Difficulty,
	joinCnt: number
): boolean
	if not (player and player.Parent) then
		return false
	end
	if not isValidDifficulty(difficulty) or not getStagePlaceId(stageNumber) then
		return false
	end
	if typeof(joinCnt) ~= "number" or joinCnt < 1 or joinCnt > 5 then
		warn("[RoomManager] tryStartParty: joinCnt는 1~5 숫자여야 함:", joinCnt)
		return false
	end
	joinCnt = math.clamp(math.floor(joinCnt), 1, 5)

	local now = os.clock()
	local portalTouchClock = lastTouchClockByPortal[portal]
	if not portalTouchClock then
		portalTouchClock = {}
		lastTouchClockByPortal[portal] = portalTouchClock
	end
	local last = portalTouchClock[player.UserId]
	if last and (now - last) < TOUCH_DEBOUNCE_SEC then
		return false
	end
	portalTouchClock[player.UserId] = now

	local ps = getOrCreatePortalState(portal)

	if ps.lobbyState == STATE_IDLE then
		-- 이미 다른 방(Recruiting/Teleporting) 또는 PVP 매치에 속해 있으면 새 파티를 시작할 수 없음.
		if userIdToRoomId[player.UserId] or isInPvpMatch(player.UserId) then
			return false
		end


		-- 리더가 (자신이 PopupOpen 중인) 다른 포탈에서 이 포탈로 이동: 이전 포탈은 정리.
		local prevPortal = leaderPortal[player.UserId]
		if prevPortal and prevPortal ~= portal then
			local prevPs = portalStates[prevPortal]
			if prevPs and prevPs.lobbyState == STATE_POPUP and prevPs.leaderUserId == player.UserId then
				print(
					string.format(
						"[RoomManager] 리더 %s 포탈 이동 → 이전 포탈 정리: %s",
						player.Name,
						prevPortal:GetFullName()
					)
				)
				transitionToIdle(prevPortal, prevPs)
			end
		end

		ps.lobbyState = STATE_POPUP
		ps.leaderUserId = player.UserId
		ps.pendingStageNumber = stageNumber
		ps.pendingDifficulty = difficulty
		ps.pendingJoinCnt = joinCnt
		leaderPortal[player.UserId] = portal
		print("[RoomManager] state → PopupOpen (leader:", player.Name, portal:GetFullName(), ")")
		if openPartyPopupEvent then
			openPartyPopupEvent:FireClient(player, {
				portal = portal,
				stageNumber = stageNumber,
				difficulty = difficulty,
				joinCnt = joinCnt,
			})
		end
		broadcastState(portal, ps)
		return true
	elseif ps.lobbyState == STATE_POPUP and ps.leaderUserId == player.UserId then
		-- 리더가 같은 포탈 위에서 재트리거: 무시
		if
			ps.pendingStageNumber == stageNumber
			and ps.pendingDifficulty == difficulty
			and ps.pendingJoinCnt == joinCnt
		then
			return false
		end
		-- 같은 포탈의 파라미터만 갱신 + popup 재발사 (Idle 경유 X)
		ps.pendingStageNumber = stageNumber
		ps.pendingDifficulty = difficulty
		ps.pendingJoinCnt = joinCnt
		print(
			string.format(
				"[RoomManager] PopupOpen 파라미터 갱신 by %s (%s) → stage=%d diff=%d joinCnt=%d",
				player.Name,
				portal:GetFullName(),
				stageNumber,
				difficulty,
				joinCnt
			)
		)
		if openPartyPopupEvent then
			openPartyPopupEvent:FireClient(player, {
				portal = portal,
				stageNumber = stageNumber,
				difficulty = difficulty,
				joinCnt = joinCnt,
			})
		end
		broadcastState(portal, ps)
		return true
	elseif ps.lobbyState == STATE_RECRUITING then
		local room = getCurrentRoom(ps)
		if not room then
			return false
		end
		if room.stageNumber ~= stageNumber or room.difficulty ~= difficulty then
			return false
		end
		if userIdToRoomId[player.UserId] then
			return false
		end
		if #room.memberUserIds >= room.capacity then
			return false
		end
		if not addMemberToRoom(room, player) then
			return false
		end
		broadcastState(portal, ps)
		if #room.memberUserIds >= room.capacity then
			print("[RoomManager] 정원 충족 → Teleporting", portal:GetFullName())
			transitionToTeleporting(portal, ps)
		end
		return true
	end
	return false
end

--- PopupOpen + pending stage/diff 가 포탈과 일치 + 터치한 플레이어가 리더가 아닐 때 true → PortalHandler가 해당 포탈 WarpPoint 로 이동.
function RoomManager.shouldEjectToWarpPointDuringPopup(
	player: Player,
	portal: Instance,
	stageNumber: number,
	difficulty: Difficulty
): boolean
	local ps = portalStates[portal]
	if not ps or ps.lobbyState ~= STATE_POPUP then
		return false
	end
	if not ps.leaderUserId or player.UserId == ps.leaderUserId then
		return false
	end
	if ps.pendingStageNumber ~= stageNumber or ps.pendingDifficulty ~= difficulty then
		return false
	end
	return true
end

--- Teleporting + 현재 방 stage/diff 가 포탈과 일치 + 터치한 플레이어가 멤버가 아닐 때 true → PortalHandler 가 WarpPoint 로 이동.
function RoomManager.shouldEjectToWarpPointDuringTeleporting(
	player: Player,
	portal: Instance,
	stageNumber: number,
	difficulty: Difficulty
): boolean
	local ps = portalStates[portal]
	if not ps or ps.lobbyState ~= STATE_TELEPORTING then
		return false
	end
	local room = getCurrentRoom(ps)
	if not room then
		return false
	end
	if room.stageNumber ~= stageNumber or room.difficulty ~= difficulty then
		return false
	end
	for _, uid in ipairs(room.memberUserIds) do
		if uid == player.UserId then
			return false
		end
	end
	return true
end

local function onCreatePartyRequest(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local portal = leaderPortal[player.UserId]
	if not portal then
		return
	end
	local ps = portalStates[portal]
	if not ps or ps.lobbyState ~= STATE_POPUP or ps.leaderUserId ~= player.UserId then
		return
	end
	local stageNumber = tonumber(payload.stageNumber)
	local difficulty = tonumber(payload.difficulty)
	local capacity = tonumber(payload.capacity)
	if not (stageNumber and difficulty and capacity) then
		warn("[RoomManager] CreatePartyRequest 인자 누락")
		transitionToIdle(portal, ps)
		return
	end
	if not isValidDifficulty(difficulty) or not getStagePlaceId(stageNumber) then
		transitionToIdle(portal, ps)
		return
	end
	if stageNumber ~= ps.pendingStageNumber or difficulty ~= ps.pendingDifficulty then
		warn("[RoomManager] CreatePartyRequest: stage/diff가 pending 과 불일치")
		transitionToIdle(portal, ps)
		return
	end
	local maxJoin = ps.pendingJoinCnt
	if not maxJoin or capacity < 1 or capacity > maxJoin or capacity ~= math.floor(capacity) then
		warn("[RoomManager] CreatePartyRequest: capacity가 유효하지 않음 (1~pendingJoinCnt)", capacity, maxJoin)
		transitionToIdle(portal, ps)
		return
	end

	local room = createRoomInternal(portal, stageNumber, difficulty, capacity)
	if not room then
		warn("[RoomManager] 방 생성 실패")
		transitionToIdle(portal, ps)
		return
	end

	if not addMemberToRoom(room, player) then
		clearRoom(room)
		transitionToIdle(portal, ps)
		return
	end

	ps.currentRoomId = room.id
	ps.lobbyState = STATE_RECRUITING
	ps.pendingStageNumber = nil
	ps.pendingDifficulty = nil
	ps.pendingJoinCnt = nil
	ps.recruitDeadline = workspace:GetServerTimeNow() + RECRUIT_TIMEOUT_SEC
	leaderPortal[player.UserId] = nil
	print(
		string.format(
			"[RoomManager] state → Recruiting (room=%s, cap=%d, %s)",
			room.id,
			room.capacity,
			portal:GetFullName()
		)
	)
	broadcastState(portal, ps)

	-- 모집 대기 동안 목적지 예약 서버를 미리 확보(텔레포트 시점 스핀업 대기 감소).
	clearReservedServer(ps)
	preloadReservedServerForRoom(room)

	if #room.memberUserIds >= room.capacity then
		transitionToTeleporting(portal, ps)
	else
		startRecruitTimeout(portal, ps)
	end
end

local function onCancelPartyRequest(player: Player)
	local portal = leaderPortal[player.UserId]
	if not portal then
		return
	end
	local ps = portalStates[portal]
	if not ps or ps.lobbyState ~= STATE_POPUP then
		return
	end
	if ps.leaderUserId ~= player.UserId then
		return
	end
	print("[RoomManager] PopupOpen 취소 by", player.Name, portal:GetFullName())
	transitionToIdle(portal, ps)
end

--- Recruiting 중인 방의 멤버가 자발적으로 퇴장. 마지막 멤버 퇴장 시 Idle 복귀.
local function onLeaveRoomRequest(player: Player)
	local roomId = userIdToRoomId[player.UserId]
	if not roomId then
		return
	end
	local room = rooms[roomId]
	if not room then
		return
	end
	local portal = room.portal
	local ps = portalStates[portal]
	if not ps or ps.lobbyState ~= STATE_RECRUITING or roomId ~= ps.currentRoomId then
		return
	end
	userIdToRoomId[player.UserId] = nil
	local idx = indexOf(room.memberUserIds, player.UserId)
	if idx then
		table.remove(room.memberUserIds, idx)
	end
	print(
		"[RoomManager]",
		player.Name,
		"←",
		room.id,
		"(LeaveRoom)",
		string.format("(%d/%d)", #room.memberUserIds, room.capacity)
	)
	if #room.memberUserIds == 0 then
		print("[RoomManager] 모집 중 마지막 멤버 퇴장 → Idle", portal:GetFullName())
		transitionToIdle(portal, ps)
	else
		broadcastState(portal, ps)
	end
end

local function onPlayerRemoving(player: Player)
	for _, portalTouchClock in pairs(lastTouchClockByPortal) do
		portalTouchClock[player.UserId] = nil
	end

	local leadingPortal = leaderPortal[player.UserId]
	if leadingPortal then
		local ps = portalStates[leadingPortal]
		if ps and ps.lobbyState == STATE_POPUP and ps.leaderUserId == player.UserId then
			print("[RoomManager] leader 퇴장 → Idle 복귀", leadingPortal:GetFullName())
			transitionToIdle(leadingPortal, ps)
		end
	end

	local roomId = userIdToRoomId[player.UserId]
	if not roomId then
		return
	end
	local room = rooms[roomId]
	userIdToRoomId[player.UserId] = nil
	if not room then
		return
	end
	local idx = indexOf(room.memberUserIds, player.UserId)
	if idx then
		table.remove(room.memberUserIds, idx)
	end
	print("[RoomManager]", player.Name, "←", room.id, string.format("(%d/%d)", #room.memberUserIds, room.capacity))

	local portal = room.portal
	local ps = portalStates[portal]
	if not ps then
		return
	end

	if ps.lobbyState == STATE_RECRUITING and room.id == ps.currentRoomId then
		if #room.memberUserIds == 0 then
			print("[RoomManager] 모집 중 마지막 멤버 퇴장 → Idle", portal:GetFullName())
			transitionToIdle(portal, ps)
		else
			broadcastState(portal, ps)
		end
	elseif ps.lobbyState == STATE_TELEPORTING and room.id == ps.currentRoomId then
		broadcastState(portal, ps)
		task.defer(function()
			tryTransitionIdleAfterTeleportIfAllGone(portal, ps)
		end)
	end
end

-- --- RemoteEvents ---

local function ensureRemoteEvent(name: string): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local ev = Instance.new("RemoteEvent")
	ev.Name = name
	ev.Parent = ReplicatedStorage
	return ev
end

function RoomManager.init()
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	local cp = ensureRemoteEvent(CREATE_PARTY_EVENT_NAME)
	local cl = ensureRemoteEvent(CANCEL_PARTY_EVENT_NAME)
	local lv = ensureRemoteEvent(LEAVE_ROOM_EVENT_NAME)
	openPartyPopupEvent = ensureRemoteEvent(OPEN_PARTY_POPUP_EVENT_NAME)
	lobbyPartyStateEvent = ensureRemoteEvent(LOBBY_PARTY_STATE_EVENT_NAME)

	cp.OnServerEvent:Connect(onCreatePartyRequest)
	cl.OnServerEvent:Connect(onCancelPartyRequest)
	lv.OnServerEvent:Connect(onLeaveRoomRequest)

	print("[RoomManager] 초기화 완료")
end

return RoomManager
