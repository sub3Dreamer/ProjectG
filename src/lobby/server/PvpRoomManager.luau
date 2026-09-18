--[[
	PvpRoomManager (lobby-only)

	StageNumber == 2 포탈 전용. Difficulty 대신 Team("Red"|"Blue") + PortalNumber 로 방을 나눈다.

	동일 PortalNumber 의 Red/Blue 포탈이 하나의 매치를 공유한다.
		Idle → Recruiting(한 명이라도 입장) → Teleporting(양팀 JoinCnt 충족) → Idle

	- 포털 Touched 시 PortalHandler가 tryJoin(..., portalNumber) 호출.
	- 입장 즉시 해당 팀 슬롯에 넣고 PvpPopupStateEvent 로 로스터 브로드캐스트.
	- LobbyPartyStateEvent 로 같은 PortalNumber 포탈 Billboard / LockWall 갱신.
	- LeavePvpRequestEvent 로 퇴장. 해당 방 전원 퇴장 시 Idle.
	- 양팀 정원이 모두 차면 Teleporting → Stage 2 PlaceId 로 ReserveServer + TeleportAsync.
]]

local PvpRoomManager = {}

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlaceIds = require(Shared.Config.PlaceIds)
local PortalLobbyWarp = require(Shared.Utils.PortalLobbyWarp)

local LobbyPhysicsSetup = require(script.Parent.LobbyPhysicsSetup)

export type TeamId = "Red" | "Blue"

export type PlayerInfo = {
	UserId: number,
	DisplayName: string,
	Team: TeamId,
}

local STATE_IDLE = "Idle"
local STATE_RECRUITING = "Recruiting"
local STATE_TELEPORTING = "Teleporting"

local PVP_STAGE_NUMBER = 2
local PVP_STATE_EVENT_NAME = "PvpPopupStateEvent"
local LEAVE_PVP_EVENT_NAME = "LeavePvpRequestEvent"
local LOBBY_PARTY_STATE_EVENT_NAME = "LobbyPartyStateEvent"
local WARP_POINT_NAME = "WarpPoint"

local TOUCH_DEBOUNCE_SEC = 0.5
local TELEPORT_IDLE_TIMEOUT_SEC = 30
local TEAM_CAPACITY_MAX = 2

PvpRoomManager.PVP_STAGE_NUMBER = PVP_STAGE_NUMBER
PvpRoomManager.PVP_STATE_EVENT_NAME = PVP_STATE_EVENT_NAME
PvpRoomManager.LEAVE_PVP_EVENT_NAME = LEAVE_PVP_EVENT_NAME

type MatchState = {
	portalNumber: number,
	lobbyState: string,
	capacityPerTeam: number,
	Blue: { PlayerInfo },
	Red: { PlayerInfo },
	--- userId → 입장한 포탈(퇴장 워프 / eject 기준)
	userPortal: { [number]: Instance },
	teleportDeadline: number?,
	teleportSerial: number,
	teleportCohortUserIds: { number }?,
	reservedPlaceId: number?,
	reservedAccessCode: string?,
	roomId: string?,
}

--- PortalNumber → 매치 (같은 번호의 Red/Blue 포탈이 공유)
local matches: { [number]: MatchState } = {}
--- userId → PortalNumber
local userIdToPortalNumber: { [number]: number } = {}

local lastTouchClock: { [number]: number } = {}
local roomIdSerial = 0

local pvpStateEvent: RemoteEvent? = nil
local lobbyPartyStateEvent: RemoteEvent? = nil

local function isInPartyRoom(userId: number): boolean
	local ok, RoomManager = pcall(function()
		return require(script.Parent.RoomManager)
	end)
	if not ok or typeof(RoomManager) ~= "table" then
		return false
	end
	local fn = (RoomManager :: any).isPlayerInRoom
	if typeof(fn) ~= "function" then
		return false
	end
	return fn(userId) == true
end

local function isValidTeam(team: any): boolean
	return team == "Red" or team == "Blue"
end

local function getStagePlaceId(stageNumber: number): number?
	local placeId = PlaceIds.Stages[stageNumber]
	if not placeId or placeId == 0 then
		return nil
	end
	return placeId
end

local function indexOfUser(list: { PlayerInfo }, userId: number): number?
	for i, info in ipairs(list) do
		if info.UserId == userId then
			return i
		end
	end
	return nil
end

local function newMatchState(portalNumber: number): MatchState
	return {
		portalNumber = portalNumber,
		lobbyState = STATE_IDLE,
		capacityPerTeam = TEAM_CAPACITY_MAX,
		Blue = {},
		Red = {},
		userPortal = {},
		teleportDeadline = nil,
		teleportSerial = 0,
		teleportCohortUserIds = nil,
		reservedPlaceId = nil,
		reservedAccessCode = nil,
		roomId = nil,
	}
end

local function getOrCreateMatch(portalNumber: number): MatchState
	local m = matches[portalNumber]
	if not m then
		m = newMatchState(portalNumber)
		matches[portalNumber] = m
	end
	return m
end

local function findPlayerTeamInMatch(match: MatchState, userId: number): TeamId?
	if indexOfUser(match.Blue, userId) then
		return "Blue"
	end
	if indexOfUser(match.Red, userId) then
		return "Red"
	end
	return nil
end

local function findPlayerMatch(userId: number): (MatchState?, TeamId?)
	local pn = userIdToPortalNumber[userId]
	if pn then
		local m = matches[pn]
		if m then
			local team = findPlayerTeamInMatch(m, userId)
			if team then
				return m, team
			end
		end
	end
	for _, m in pairs(matches) do
		local team = findPlayerTeamInMatch(m, userId)
		if team then
			return m, team
		end
	end
	return nil, nil
end

function PvpRoomManager.isPlayerInMatch(userId: number): boolean
	local m = findPlayerMatch(userId)
	return m ~= nil
end

local function totalMembers(match: MatchState): number
	return #match.Blue + #match.Red
end

local function collectMemberUserIds(match: MatchState): { number }
	local ids: { number } = {}
	for _, info in ipairs(match.Blue) do
		table.insert(ids, info.UserId)
	end
	for _, info in ipairs(match.Red) do
		table.insert(ids, info.UserId)
	end
	return ids
end

local function collectMatchPlayers(match: MatchState): { Player }
	local list: { Player } = {}
	for _, uid in ipairs(collectMemberUserIds(match)) do
		local p = Players:GetPlayerByUserId(uid)
		if p then
			table.insert(list, p)
		end
	end
	return list
end

local function makePlayerInfo(player: Player, team: TeamId): PlayerInfo
	return {
		UserId = player.UserId,
		DisplayName = player.DisplayName,
		Team = team,
	}
end

local function cloneRosterPayload(match: MatchState)
	return {
		Blue = table.clone(match.Blue),
		Red = table.clone(match.Red),
		state = match.lobbyState,
		stageNumber = PVP_STAGE_NUMBER,
		portalNumber = match.portalNumber,
		capacityPerTeam = match.capacityPerTeam,
	}
end

local function clearReservedServer(match: MatchState)
	match.reservedPlaceId = nil
	match.reservedAccessCode = nil
end

local function readPortalNumber(inst: Instance): number?
	local n = inst:GetAttribute("PortalNumber")
	if typeof(n) == "number" and n == n and n >= 1 then
		return math.floor(n)
	end
	return nil
end

local function isPvpPortal(inst: Instance): boolean
	if not (inst:IsA("Model") or inst:IsA("BasePart")) then
		return false
	end
	if inst:GetAttribute("Portal") ~= true then
		return false
	end
	local team = inst:GetAttribute("Team")
	if not isValidTeam(team) then
		return false
	end
	return readPortalNumber(inst) ~= nil
end

local function collectPvpPortals(portalNumber: number?): { Instance }
	local list: { Instance } = {}
	for _, d in Workspace:GetDescendants() do
		if isPvpPortal(d) then
			local pn = readPortalNumber(d)
			if portalNumber == nil or pn == portalNumber then
				table.insert(list, d)
			end
		end
	end
	return list
end

local function buildPortalStatePayload(portal: Instance, match: MatchState)
	local teamAttr = portal:GetAttribute("Team")
	local team: TeamId? = if isValidTeam(teamAttr) then (teamAttr :: TeamId) else nil
	local teamList = if team == "Blue" then match.Blue elseif team == "Red" then match.Red else {}
	local memberIds = collectMemberUserIds(match)

	return {
		portal = portal,
		state = match.lobbyState,
		stageNumber = PVP_STAGE_NUMBER,
		portalNumber = match.portalNumber,
		team = team,
		difficulty = nil,
		capacity = match.capacityPerTeam,
		current = #teamList,
		memberUserIds = if #memberIds > 0 then memberIds else nil,
		recruitDeadline = nil,
		teleportDeadline = match.teleportDeadline,
		teleportDelaySec = (match.lobbyState == STATE_TELEPORTING) and TELEPORT_IDLE_TIMEOUT_SEC or nil,
		mode = "Pvp",
	}
end

local function setMatchLockWalls(match: MatchState, blocksEveryone: boolean)
	for _, portal in ipairs(collectPvpPortals(match.portalNumber)) do
		LobbyPhysicsSetup.setPortalLockWallBlocksEveryone(portal, blocksEveryone)
	end
end

local function broadcastLobbyStates(match: MatchState)
	if lobbyPartyStateEvent then
		for _, portal in ipairs(collectPvpPortals(match.portalNumber)) do
			lobbyPartyStateEvent:FireAllClients(buildPortalStatePayload(portal, match))
		end
	end
	setMatchLockWalls(match, match.lobbyState == STATE_TELEPORTING)
end

local function broadcastPvpRoster(match: MatchState)
	if not pvpStateEvent then
		return
	end
	local payload = cloneRosterPayload(match)
	for _, player in ipairs(collectMatchPlayers(match)) do
		pvpStateEvent:FireClient(player, payload)
	end
end

local function broadcastAll(match: MatchState)
	broadcastLobbyStates(match)
	broadcastPvpRoster(match)
end

local function resetMatchToIdle(match: MatchState)
	for uid in pairs(match.userPortal) do
		userIdToPortalNumber[uid] = nil
	end
	match.lobbyState = STATE_IDLE
	match.capacityPerTeam = TEAM_CAPACITY_MAX
	match.Blue = {}
	match.Red = {}
	match.userPortal = {}
	match.teleportDeadline = nil
	match.teleportSerial += 1
	match.teleportCohortUserIds = nil
	match.roomId = nil
	clearReservedServer(match)
	broadcastAll(match)
	print("[PvpRoomManager] state → Idle portalNumber=", match.portalNumber)
end

local function bothTeamsFull(match: MatchState): boolean
	local cap = match.capacityPerTeam
	return #match.Blue >= cap and #match.Red >= cap
end

local function preloadReservedServer(match: MatchState)
	local placeId = getStagePlaceId(PVP_STAGE_NUMBER)
	if not placeId then
		return
	end
	local serialRoomId = match.roomId
	local portalNumber = match.portalNumber
	task.spawn(function()
		local code: string?
		local ok, err = pcall(function()
			code = TeleportService:ReserveServer(placeId)
		end)
		if not ok or not code then
			warn("[PvpRoomManager] 사전 ReserveServer 실패:", err)
			return
		end
		local m = matches[portalNumber]
		if not m or m.roomId ~= serialRoomId or m.lobbyState == STATE_IDLE then
			return
		end
		m.reservedPlaceId = placeId
		m.reservedAccessCode = code
		print("[PvpRoomManager] 예약 서버 사전 확보 완료 room=", serialRoomId, "portalNumber=", portalNumber)
	end)
end

local function buildTeleportData(match: MatchState)
	local blueIds: { number } = {}
	local redIds: { number } = {}
	for _, info in ipairs(match.Blue) do
		table.insert(blueIds, info.UserId)
	end
	for _, info in ipairs(match.Red) do
		table.insert(redIds, info.UserId)
	end
	return {
		stageNumber = PVP_STAGE_NUMBER,
		difficulty = 1,
		roomId = match.roomId,
		portalNumber = match.portalNumber,
		capacity = match.capacityPerTeam * 2,
		mode = "Pvp",
		teams = {
			Blue = blueIds,
			Red = redIds,
		},
	}
end

local function tryTransitionIdleAfterTeleportIfAllGone(match: MatchState)
	if match.lobbyState ~= STATE_TELEPORTING then
		return
	end
	if not match.teleportCohortUserIds then
		return
	end
	for _, uid in ipairs(match.teleportCohortUserIds) do
		if Players:GetPlayerByUserId(uid) ~= nil then
			return
		end
	end
	print("[PvpRoomManager] Teleport 코호트 전원 로비 이탈 → Idle portalNumber=", match.portalNumber)
	resetMatchToIdle(match)
end

local function warpPlayerToJoinedPortal(player: Player, match: MatchState, team: TeamId)
	local portal = match.userPortal[player.UserId]
	if portal then
		local char = player.Character
		if char and char:IsA("Model") then
			local hum = char:FindFirstChildOfClass("Humanoid")
			local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
			local w = portal:FindFirstChild(WARP_POINT_NAME, true)
			if hum and hrp and w and w:IsA("BasePart") then
				local yLift = w.Size.Y * 0.5 + hum.HipHeight + 0.5
				local targetCf = w.CFrame * CFrame.new(0, yLift, 0)
				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.AssemblyAngularVelocity = Vector3.zero
				char:PivotTo(targetCf)
				return
			end
		end
	end
	PortalLobbyWarp.warpPlayerToStageTeamWarpPoint(player, PVP_STAGE_NUMBER, team, match.portalNumber)
end

local function finalDispatch(match: MatchState, teleportOpSerial: number)
	local placeId = getStagePlaceId(PVP_STAGE_NUMBER)
	if not placeId then
		warn("[PvpRoomManager] PlaceId 없음 stage=", PVP_STAGE_NUMBER)
		resetMatchToIdle(match)
		return
	end
	local players = collectMatchPlayers(match)
	if #players == 0 then
		resetMatchToIdle(match)
		return
	end

	local code: string? = nil
	if match.reservedAccessCode and match.reservedPlaceId == placeId then
		code = match.reservedAccessCode
	else
		local okReserve, errReserve = pcall(function()
			code = TeleportService:ReserveServer(placeId)
		end)
		if not okReserve or not code then
			warn("[PvpRoomManager] ReserveServer 실패:", errReserve)
			for _, p in ipairs(players) do
				local team = findPlayerTeamInMatch(match, p.UserId)
				if team then
					warpPlayerToJoinedPortal(p, match, team)
				end
			end
			resetMatchToIdle(match)
			return
		end
	end
	clearReservedServer(match)

	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = code
	options:SetTeleportData(buildTeleportData(match))

	local livePlayers: { Player } = {}
	for _, p in ipairs(players) do
		if p and p.Parent then
			table.insert(livePlayers, p)
		end
	end

	local cohort: { number } = {}
	local okBatch, errBatch = pcall(function()
		TeleportService:TeleportAsync(placeId, livePlayers, options)
	end)
	if okBatch then
		for _, p in ipairs(livePlayers) do
			table.insert(cohort, p.UserId)
		end
	else
		warn("[PvpRoomManager] TeleportAsync 배치 실패 → 개별 재시도:", errBatch)
		for _, p in ipairs(livePlayers) do
			if p and p.Parent then
				local okT, errT = pcall(function()
					TeleportService:TeleportAsync(placeId, { p }, options)
				end)
				if okT then
					table.insert(cohort, p.UserId)
				else
					warn("[PvpRoomManager] TeleportAsync 실패:", p.Name, errT)
					local team = findPlayerTeamInMatch(match, p.UserId)
					if team then
						warpPlayerToJoinedPortal(p, match, team)
					end
				end
			end
		end
	end

	if #cohort == 0 then
		warn("[PvpRoomManager] TeleportAsync 전원 실패 → Idle")
		resetMatchToIdle(match)
		return
	end

	match.teleportCohortUserIds = cohort
	print(
		string.format(
			"[PvpRoomManager] 텔레포트 요청 완료 (성공 %d/%d, portalNumber=%d)",
			#cohort,
			#players,
			match.portalNumber
		)
	)
	tryTransitionIdleAfterTeleportIfAllGone(match)

	local portalNumber = match.portalNumber
	task.delay(TELEPORT_IDLE_TIMEOUT_SEC, function()
		local m = matches[portalNumber]
		if not m or teleportOpSerial ~= m.teleportSerial then
			return
		end
		if m.lobbyState ~= STATE_TELEPORTING then
			return
		end
		print(
			string.format(
				"[PvpRoomManager] Teleport Idle 타임아웃(%ds) → Idle portalNumber=%d",
				TELEPORT_IDLE_TIMEOUT_SEC,
				portalNumber
			)
		)
		resetMatchToIdle(m)
	end)
end

local function transitionToTeleporting(match: MatchState)
	if match.lobbyState == STATE_TELEPORTING then
		return
	end
	if not bothTeamsFull(match) then
		return
	end
	match.lobbyState = STATE_TELEPORTING
	match.teleportDeadline = workspace:GetServerTimeNow() + TELEPORT_IDLE_TIMEOUT_SEC
	print("[PvpRoomManager] state → Teleporting portalNumber=", match.portalNumber)

	task.defer(function()
		broadcastAll(match)
	end)

	match.teleportSerial += 1
	local s = match.teleportSerial
	finalDispatch(match, s)
end

local function removePlayerFromMatch(userId: number): (MatchState?, TeamId?)
	local match, team = findPlayerMatch(userId)
	if not match or not team then
		return nil, nil
	end
	local list = match[team]
	local idx = indexOfUser(list, userId)
	if idx then
		table.remove(list, idx)
	end
	match.userPortal[userId] = nil
	userIdToPortalNumber[userId] = nil
	return match, team
end

--- 포털 Touched 시 호출. Team + PortalNumber 포탈에서만 사용.
function PvpRoomManager.tryJoin(
	player: Player,
	portal: Instance,
	stageNumber: number,
	team: TeamId,
	joinCnt: number,
	portalNumber: number
): boolean
	if not (player and player.Parent) then
		return false
	end
	if stageNumber ~= PVP_STAGE_NUMBER or not isValidTeam(team) then
		return false
	end
	if typeof(portalNumber) ~= "number" or portalNumber < 1 then
		warn("[PvpRoomManager] tryJoin: PortalNumber 필요")
		return false
	end
	portalNumber = math.floor(portalNumber)
	if not getStagePlaceId(PVP_STAGE_NUMBER) then
		return false
	end
	if typeof(joinCnt) ~= "number" or joinCnt < 1 then
		return false
	end
	joinCnt = math.clamp(math.floor(joinCnt), 1, TEAM_CAPACITY_MAX)

	local now = os.clock()
	local last = lastTouchClock[player.UserId]
	if last and (now - last) < TOUCH_DEBOUNCE_SEC then
		return false
	end
	lastTouchClock[player.UserId] = now

	local match = getOrCreateMatch(portalNumber)

	if match.lobbyState == STATE_TELEPORTING then
		return false
	end
	if isInPartyRoom(player.UserId) then
		return false
	end

	local existingMatch = findPlayerMatch(player.UserId)
	if existingMatch then
		return false
	end

	if match.lobbyState == STATE_IDLE then
		match.lobbyState = STATE_RECRUITING
		match.capacityPerTeam = joinCnt
		match.Blue = {}
		match.Red = {}
		match.userPortal = {}
		roomIdSerial += 1
		match.roomId = string.format("PVP-S%d-P%d-#%d", PVP_STAGE_NUMBER, portalNumber, roomIdSerial)
		clearReservedServer(match)
		preloadReservedServer(match)
		print("[PvpRoomManager] state → Recruiting portalNumber=", portalNumber, "cap/team=", joinCnt)
	end

	if joinCnt < match.capacityPerTeam and #match[team] < joinCnt then
		match.capacityPerTeam = joinCnt
	end

	local teamList = match[team]
	if #teamList >= match.capacityPerTeam then
		return false
	end

	table.insert(teamList, makePlayerInfo(player, team))
	match.userPortal[player.UserId] = portal
	userIdToPortalNumber[player.UserId] = portalNumber
	print(
		string.format(
			"[PvpRoomManager] %s → P%d %s (%d/%d) Blue=%d Red=%d",
			player.Name,
			portalNumber,
			team,
			#teamList,
			match.capacityPerTeam,
			#match.Blue,
			#match.Red
		)
	)

	broadcastAll(match)

	if bothTeamsFull(match) then
		transitionToTeleporting(match)
	end
	return true
end

function PvpRoomManager.shouldEjectToWarpPointDuringTeleporting(
	player: Player,
	portal: Instance,
	stageNumber: number,
	team: TeamId,
	portalNumber: number?
): boolean
	if stageNumber ~= PVP_STAGE_NUMBER or not isValidTeam(team) then
		return false
	end
	local pn = portalNumber or readPortalNumber(portal)
	if not pn then
		return false
	end
	local match = matches[pn]
	if not match or match.lobbyState ~= STATE_TELEPORTING then
		return false
	end
	if findPlayerTeamInMatch(match, player.UserId) then
		return false
	end
	if not isPvpPortal(portal) then
		return false
	end
	return true
end

local function onLeavePvpRequest(player: Player)
	local match, team = findPlayerMatch(player.UserId)
	if not match or not team then
		return
	end
	if match.lobbyState == STATE_TELEPORTING then
		return
	end

	-- 퇴장 워프용 포탈을 멤버 제거 전에 보관
	local joinedPortal = match.userPortal[player.UserId]
	removePlayerFromMatch(player.UserId)
	print("[PvpRoomManager]", player.Name, "← leave", team, "portalNumber=", match.portalNumber)

	if pvpStateEvent then
		pvpStateEvent:FireClient(player, {
			Blue = {},
			Red = {},
			state = STATE_IDLE,
			stageNumber = PVP_STAGE_NUMBER,
			portalNumber = match.portalNumber,
		})
	end

	if joinedPortal then
		match.userPortal[player.UserId] = joinedPortal
		warpPlayerToJoinedPortal(player, match, team)
		match.userPortal[player.UserId] = nil
	else
		PortalLobbyWarp.warpPlayerToStageTeamWarpPoint(player, PVP_STAGE_NUMBER, team, match.portalNumber)
	end

	if totalMembers(match) == 0 then
		resetMatchToIdle(match)
	else
		broadcastAll(match)
	end
end

local function onPlayerRemoving(player: Player)
	lastTouchClock[player.UserId] = nil
	local match, team = removePlayerFromMatch(player.UserId)
	if not match then
		for _, m in pairs(matches) do
			if m.lobbyState == STATE_TELEPORTING then
				task.defer(function()
					tryTransitionIdleAfterTeleportIfAllGone(m)
				end)
			end
		end
		return
	end
	print("[PvpRoomManager]", player.Name, "← removing", team, "portalNumber=", match.portalNumber)

	if match.lobbyState == STATE_TELEPORTING then
		broadcastAll(match)
		task.defer(function()
			tryTransitionIdleAfterTeleportIfAllGone(match)
		end)
		return
	end

	if totalMembers(match) == 0 then
		resetMatchToIdle(match)
	else
		broadcastAll(match)
	end
end

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

function PvpRoomManager.init()
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	pvpStateEvent = ensureRemoteEvent(PVP_STATE_EVENT_NAME)
	local leaveEv = ensureRemoteEvent(LEAVE_PVP_EVENT_NAME)
	lobbyPartyStateEvent = ensureRemoteEvent(LOBBY_PARTY_STATE_EVENT_NAME)

	leaveEv.OnServerEvent:Connect(onLeavePvpRequest)

	print("[PvpRoomManager] 초기화 완료")
end

return PvpRoomManager
