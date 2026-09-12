--[[
	LobbyPhysicsSetup

	- LobbyLockedMember(공유) / 포탈별 LobbyLockedWall_N CollisionGroup 등록
	- 기본: 벽(Default) ↔ 그 포탈의 LOCK_WALL 충돌 끔 → 일반 플레이어는 벽을 통과
	- LOCK_WALL ↔ LOCKED_MEMBER 충돌 켬 → 잠긴 멤버만 벽에 막힘
	- RoomManager 가 특정 포탈에서 PopupOpen / Teleporting 일 때만
	  setPortalLockWallBlocksEveryone(portal, true) 로 그 포탈의 Default ↔ LOCK_WALL 충돌만 켜서
	  다른 포탈의 벽에는 영향이 없게 한다.

	Workspace 의 BasePart 중 Attribute LobbyLockWall=true 인 것을, 가장 가까운 Portal(Attribute
	Portal=true) 인스턴스에 매칭해 그 포탈 전용 CollisionGroup 으로 설정한다.
]]

local PhysicsService = game:GetService("PhysicsService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyPhysicsGroups = require(Shared.Config.LobbyPhysicsGroups)

local WALL_GROUP_PREFIX = LobbyPhysicsGroups.LOCK_WALL_GROUP_PREFIX
local MEMBER = LobbyPhysicsGroups.LOCKED_MEMBER
local ATTR = LobbyPhysicsGroups.ATTR_LOCK_WALL

local portalInstances: { Instance } = {}
local portalWallGroups: { [Instance]: string } = {}
local groupSerial = 0

local function isPortalInstance(inst: Instance): boolean
	if not (inst:IsA("Model") or inst:IsA("BasePart")) then
		return false
	end
	return inst:GetAttribute("Portal") == true
end

local function portalPosition(portal: Instance): Vector3?
	if portal:IsA("Model") then
		return (portal :: Model):GetPivot().Position
	elseif portal:IsA("BasePart") then
		return (portal :: BasePart).Position
	end
	return nil
end

--- 등록된(스캔된) Portal 인스턴스 중 pos 에 가장 가까운 것을 찾는다.
--- WarpPoint 매칭(PortalLobbyWarp/PortalWarp)과 동일한 "최근접" 규칙.
local function pickNearestPortal(pos: Vector3): Instance?
	local best: Instance? = nil
	local bestDist = math.huge
	for _, portal in ipairs(portalInstances) do
		local p = portalPosition(portal)
		if p then
			local d = (p - pos).Magnitude
			if d < bestDist then
				bestDist = d
				best = portal
			end
		end
	end
	return best
end

local function getOrCreatePortalWallGroup(portal: Instance): string
	local existing = portalWallGroups[portal]
	if existing then
		return existing
	end

	groupSerial += 1
	local name = WALL_GROUP_PREFIX .. tostring(groupSerial)

	local ok = pcall(function()
		PhysicsService:RegisterCollisionGroup(name)
	end)
	if not ok then
		warn("[LobbyPhysicsSetup] CollisionGroup 등록 실패 (32개 한도 확인 필요):", name)
	end

	-- 일반 월드(Default)는 벽을 통과
	PhysicsService:CollisionGroupSetCollidable(name, "Default", false)
	-- 잠긴 멤버만 벽과 충돌
	PhysicsService:CollisionGroupSetCollidable(name, MEMBER, true)
	-- 벽끼리 충돌 불필요
	PhysicsService:CollisionGroupSetCollidable(name, name, false)

	portalWallGroups[portal] = name
	return name
end

local function registerMemberGroup()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(MEMBER)
	end)
end

local function applyWallGroupIfTagged(inst: Instance)
	if not (inst:IsA("BasePart") and inst:GetAttribute(ATTR) == true) then
		return
	end
	local part = inst :: BasePart
	local portal = pickNearestPortal(part.Position)
	if not portal then
		warn("[LobbyPhysicsSetup] LockWall 근처에 Portal 인스턴스를 찾지 못함:", part:GetFullName())
		return
	end
	part.CollisionGroup = getOrCreatePortalWallGroup(portal)
end

local function scanPortals()
	for _, d in Workspace:GetDescendants() do
		if isPortalInstance(d) then
			table.insert(portalInstances, d)
		end
	end
	Workspace.DescendantAdded:Connect(function(d: Instance)
		if isPortalInstance(d) then
			table.insert(portalInstances, d)
		end
	end)
end

local function bindWallScanner()
	for _, d in Workspace:GetDescendants() do
		applyWallGroupIfTagged(d)
	end
	Workspace.DescendantAdded:Connect(applyWallGroupIfTagged)
end

local LobbyPhysicsSetup = {}

--- 특정 포탈에서만 true: 그 포탈의 LobbyLockWall 벽만 Default 캐릭터와 충돌하게 한다.
--- 다른 포탈의 벽에는 영향을 주지 않는다.
function LobbyPhysicsSetup.setPortalLockWallBlocksEveryone(portal: Instance, enabled: boolean)
	local name = getOrCreatePortalWallGroup(portal)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(name, "Default", enabled)
	end)
end

function LobbyPhysicsSetup.init()
	registerMemberGroup()
	scanPortals()
	bindWallScanner()
	print("[LobbyPhysicsSetup] CollisionGroup 등록 및 포탈별 LobbyLockWall 벽 스캔 완료")
end

return LobbyPhysicsSetup
