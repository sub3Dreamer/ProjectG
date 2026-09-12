--[[
	LobbyMemberLock (lobby client)

	아래 조건일 때만 로컬 캐릭터의 CollisionGroup 을 LobbyLockedMember 로 설정한다.
		- state == PopupOpen 이고 로컬 플레이어가 leader 인 경우 → 포털 영역 이탈 방지
		- state == Recruiting / Teleporting 이고 로컬 플레이어가 memberUserIds 에 포함된 경우

	서버 매트릭스: Recruiting 일 때는 LOCKED_MEMBER 만 벽과 충돌, Default 는 통과.
	PopupOpen / Teleporting 일 때는 Default 도 벽과 충돌(전원 막힘).
	LobbyLockWall Attribute 가 붙은 벽에만 해당.

	벽 배치: Workspace 안 BasePart 에 Attribute LobbyLockWall=true (수평 링·원통 등 디자인은 스튜디오에서)

	서버: LobbyPhysicsSetup (CollisionGroup 등록 + 태그된 벽에 LOCK_WALL 적용)
]]

local LobbyMemberLock = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyPhysicsGroups = require(Shared.Config.LobbyPhysicsGroups)

local LOBBY_PARTY_STATE_EVENT_NAME = "LobbyPartyStateEvent"
local STATE_IDLE = "Idle"
local STATE_POPUP = "PopupOpen"

local MEMBER_GROUP = LobbyPhysicsGroups.LOCKED_MEMBER

local localPlayer = Players.LocalPlayer
local initialized = false

local lastState: any = nil
--- 현재 이 클라이언트를 "잠금 대상"으로 만들고 있는 포탈(있다면). 다른(무관한) 포탈의
--- LobbyPartyStateEvent 브로드캐스트가 이 값을 덮어써 잘못 잠금 해제하지 않도록 막는 용도.
local lockedPortal: Instance? = nil
local charPartConn: RBXScriptConnection? = nil

-- --- 멤버 판정 ---

local function isLocalPlayerInMembers(state: any): boolean
	if not (state and state.memberUserIds) then
		return false
	end
	for _, uid in ipairs(state.memberUserIds) do
		if uid == localPlayer.UserId then
			return true
		end
	end
	return false
end

local function isLocalPlayerInvolved(state: any): boolean
	if not state then
		return false
	end
	if state.leaderUserId == localPlayer.UserId then
		return true
	end
	return isLocalPlayerInMembers(state)
end

local function shouldLock(): boolean
	local s = lastState
	if not s or s.state == STATE_IDLE then
		return false
	end
	-- PopupOpen 동안에는 아직 room 이 없어 memberUserIds 가 비어있다.
	-- leader 본인만 포털 영역에 가둔다.
	if s.state == STATE_POPUP then
		return s.leaderUserId == localPlayer.UserId
	end
	-- Recruiting / Teleporting: 멤버에 포함되어 있으면 잠금
	return isLocalPlayerInMembers(s)
end

-- --- CollisionGroup 적용 (LOCKED_MEMBER) ---

local function disconnectCharPartListener()
	if charPartConn then
		charPartConn:Disconnect()
		charPartConn = nil
	end
end

local function applyLockedMember(char: Model)
	disconnectCharPartListener()
	local function setOne(p: BasePart)
		p.CollisionGroup = MEMBER_GROUP
	end
	for _, d in char:GetDescendants() do
		if d:IsA("BasePart") then
			setOne(d :: BasePart)
		end
	end
	charPartConn = char.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			setOne(d :: BasePart)
		end
	end)
end

local function clearLockedMember(char: Model?)
	disconnectCharPartListener()
	if not char then
		return
	end
	for _, d in char:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = "Default"
		end
	end
end

local function syncLockToCurrentCharacter()
	local char = localPlayer.Character
	if shouldLock() then
		if char then
			applyLockedMember(char)
		end
	else
		clearLockedMember(char)
	end
end

local function evaluateState()
	syncLockToCurrentCharacter()
end

-- --- public ---

function LobbyMemberLock.init()
	if initialized then
		return
	end
	initialized = true

	localPlayer.CharacterAdded:Connect(function(char)
		if shouldLock() then
			applyLockedMember(char)
		else
			clearLockedMember(char)
		end
	end)

	task.spawn(function()
		local stateEv = ReplicatedStorage:WaitForChild(LOBBY_PARTY_STATE_EVENT_NAME) :: RemoteEvent
		stateEv.OnClientEvent:Connect(function(payload)
			if typeof(payload) ~= "table" then
				return
			end
			-- 이미 나를 잠근 포탈에 대한 갱신, 또는 내가 새로 연관된 포탈일 때만 반영.
			-- (무관한 다른 포탈의 브로드캐스트가 내 잠금 상태를 덮어쓰지 않도록 함)
			local relevant = (payload.portal == lockedPortal) or isLocalPlayerInvolved(payload)
			if not relevant then
				return
			end
			lastState = payload
			lockedPortal = (payload.state ~= STATE_IDLE) and payload.portal or nil
			evaluateState()
		end)
	end)

	if localPlayer.Character then
		syncLockToCurrentCharacter()
	end

	print("[LobbyMemberLock] 초기화 완료 (CollisionGroup 방식)")
end

return LobbyMemberLock
