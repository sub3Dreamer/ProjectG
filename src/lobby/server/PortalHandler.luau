--[[
	PortalHandler (lobby-only)

	Workspace에서 attribute Portal=true 인 Model/BasePart 를 찾아
	플레이어가 "처음 올라서는 순간"에만 RoomManager.tryStartParty 를 호출.

	기대 attribute:
		- Portal       : bool   (true 인 인스턴스만 후킹)
		- StageNumber  : number (1~)
		- Difficulty   : number (1=쉬움, 2=일반, 3=어려움)
		- JoinCnt      : number (1~5, 파티 팝업 최대 정원·토글 개수; 없으면 기본 5)

	Model 인 경우 자식 중 "TouchPart"가 있으면 그것만, 없으면 모델 내 모든 BasePart에 연결.

	enter 감지:
		Touched/TouchEnded 의 캐릭터 Part 카운트를 (portal, userId) 단위로 기록.
		count: 0 → 1 변환 시점에만 tryStartParty 호출 (또는 PopupOpen 비리더 / Teleporting 비멤버면 해당 포탈 WarpPoint 로 서버 이동만).
		플레이어가 페데스탈에서 완전히 내려가야(count == 0) 다시 enter 가능.
		→ 팝업 닫은 후 같은 자리에 서 있으면 재트리거되지 않음.
]]

local PortalHandler = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyPhysicsGroups = require(Shared.Config.LobbyPhysicsGroups)

local RoomManager = require(script.Parent.RoomManager)

local ATTR_LOCK_WALL = LobbyPhysicsGroups.ATTR_LOCK_WALL
local WARP_POINT_NAME = "WarpPoint"

local function isLockWall(inst: Instance): boolean
	return inst:GetAttribute(ATTR_LOCK_WALL) == true
end

local boundInstances: { [Instance]: boolean } = {}

-- (portalInstance) -> ( userId -> 접촉 중인 캐릭터 BasePart 의 set )
-- 동일 포털을 여러 캐릭터 Part 가 동시에 밟아도 "처음 올라설 때만" tryStartParty 가 호출되도록 카운팅.
local contactPartsByPortal: { [Instance]: { [number]: { [BasePart]: boolean } } } = {}

local function isPortalInstance(inst: Instance): boolean
	if not (inst:IsA("Model") or inst:IsA("BasePart")) then
		return false
	end
	return inst:GetAttribute("Portal") == true
end

local function collectTouchParts(inst: Instance): { BasePart }
	local list: { BasePart } = {}
	if inst:IsA("BasePart") then
		if not isLockWall(inst) then
			table.insert(list, inst :: BasePart)
		end
		return list
	end
	if inst:IsA("Model") then
		local explicit = inst:FindFirstChild("TouchPart")
		if explicit and explicit:IsA("BasePart") then
			if not isLockWall(explicit) then
				table.insert(list, explicit :: BasePart)
			end
			return list
		end
		for _, d in inst:GetDescendants() do
			if d:IsA("BasePart") and not isLockWall(d) then
				table.insert(list, d :: BasePart)
			end
		end
	end
	return list
end

local function getOrCreatePortalMap(portal: Instance): { [number]: { [BasePart]: boolean } }
	local m = contactPartsByPortal[portal]
	if not m then
		m = {}
		contactPartsByPortal[portal] = m
	end
	return m
end

--- 해당 포탈 모델/파트 하위 WarpPoint(BasePart) 위로 캐릭터를 옮긴다 (클라 PortalWarp 와 동일한 오프셋 규칙).
local function warpCharacterToPortalWarpPoint(char: Model, portal: Instance): boolean
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not hrp then
		return false
	end
	local w = portal:FindFirstChild(WARP_POINT_NAME, true)
	if not w or not w:IsA("BasePart") then
		warn(
			string.format(
				"[PortalHandler] WarpPoint 없음 (비파티원/비리더 밀어내기) — %s",
				portal:GetFullName()
			)
		)
		return false
	end
	local targetPart = w :: BasePart
	local yLift = targetPart.Size.Y * 0.5 + hum.HipHeight + 0.5
	local targetCf = targetPart.CFrame * CFrame.new(0, yLift, 0)
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	char:PivotTo(targetCf)
	return true
end

local function onPortalTouched(portal: Instance, hit: BasePart)
	if not hit or not hit:IsA("BasePart") then
		return
	end
	local char = hit.Parent
	if not char then
		return
	end
	local player = Players:GetPlayerFromCharacter(char)
	if not player then
		return
	end

	local stage = portal:GetAttribute("StageNumber")
	local difficulty = portal:GetAttribute("Difficulty")
	if typeof(stage) ~= "number" or typeof(difficulty) ~= "number" then
		return
	end

	local joinRaw = portal:GetAttribute("JoinCnt")
	local joinCnt = 5
	if typeof(joinRaw) == "number" then
		joinCnt = math.clamp(math.floor(joinRaw), 1, 5)
	else
		warn("[PortalHandler] JoinCnt(number) 없음 → 기본 5 사용:", portal:GetFullName())
	end

	local portalMap = getOrCreatePortalMap(portal)
	local set = portalMap[player.UserId]
	if not set then
		set = {}
		portalMap[player.UserId] = set
	end
	if set[hit] then
		return
	end
	local wasEmpty = next(set) == nil
	set[hit] = true
	if wasEmpty then
		if RoomManager.shouldEjectToWarpPointDuringPopup(player, portal, stage, difficulty) then
			if char:IsA("Model") then
				warpCharacterToPortalWarpPoint(char :: Model, portal)
			end
			return
		end
		if RoomManager.shouldEjectToWarpPointDuringTeleporting(player, portal, stage, difficulty) then
			if char:IsA("Model") then
				warpCharacterToPortalWarpPoint(char :: Model, portal)
			end
			return
		end
		RoomManager.tryStartParty(player, portal, stage, difficulty, joinCnt)
	end
end

local function onPortalTouchEnded(portal: Instance, hit: BasePart)
	if not hit or not hit:IsA("BasePart") then
		return
	end
	local char = hit.Parent
	if not char then
		return
	end
	local player = Players:GetPlayerFromCharacter(char)
	if not player then
		return
	end
	local portalMap = contactPartsByPortal[portal]
	if not portalMap then
		return
	end
	local set = portalMap[player.UserId]
	if not set then
		return
	end
	if not set[hit] then
		return
	end
	set[hit] = nil
	if next(set) == nil then
		portalMap[player.UserId] = nil
	end
end

local function clearAllContactsForPlayer(userId: number)
	for _, portalMap in pairs(contactPartsByPortal) do
		portalMap[userId] = nil
	end
end

local function clearAllContactsForPortal(portal: Instance)
	contactPartsByPortal[portal] = nil
end

local function bindPortal(inst: Instance)
	if boundInstances[inst] then
		return
	end
	if not isPortalInstance(inst) then
		return
	end

	local stage = inst:GetAttribute("StageNumber")
	local difficulty = inst:GetAttribute("Difficulty")
	if typeof(stage) ~= "number" or typeof(difficulty) ~= "number" then
		warn("[PortalHandler] StageNumber/Difficulty(number) 누락:", inst:GetFullName())
		return
	end

	local parts = collectTouchParts(inst)
	if #parts == 0 then
		warn("[PortalHandler] 터치 가능한 BasePart 없음:", inst:GetFullName())
		return
	end

	for _, part in parts do
		part.Touched:Connect(function(hit: BasePart)
			onPortalTouched(inst, hit)
		end)
		part.TouchEnded:Connect(function(hit: BasePart)
			onPortalTouchEnded(inst, hit)
		end)
	end

	inst.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			clearAllContactsForPortal(inst)
			boundInstances[inst] = nil
		end
	end)

	boundInstances[inst] = true
	print(
		string.format(
			"[PortalHandler] 포털 등록: %s (stage=%d, diff=%d, parts=%d)",
			inst:GetFullName(),
			stage,
			difficulty,
			#parts
		)
	)
end

local function scanAll()
	for _, d in Workspace:GetDescendants() do
		if isPortalInstance(d) then
			bindPortal(d)
		end
	end
end

function PortalHandler.init()
	scanAll()

	Workspace.DescendantAdded:Connect(function(d: Instance)
		if isPortalInstance(d) then
			bindPortal(d)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		clearAllContactsForPlayer(player.UserId)
	end)

	Players.PlayerAdded:Connect(function(player)
		player.CharacterRemoving:Connect(function()
			-- 캐릭터 사망/리셋 시 잔존 카운트 정리 (TouchEnded 누락 방어)
			clearAllContactsForPlayer(player.UserId)
		end)
	end)
	for _, p in Players:GetPlayers() do
		p.CharacterRemoving:Connect(function()
			clearAllContactsForPlayer(p.UserId)
		end)
	end

	print("[PortalHandler] 초기화 완료")
end

return PortalHandler
