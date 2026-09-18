--[[
	PortalLobbyWarp (shared, 서버·클라 모두 사용 가능)

	로비 Workspace 에서 Portal=true 이고 StageNumber/Difficulty(또는 Team) 가 일치하는 포탈들의
	WarpPoint(BasePart) 중, 플레이어 HumanoidRootPart 에 가장 가까운 것으로 캐릭터를 옮긴다.
	클라 PortalWarp 와 동일한 탐색·오프셋 규칙.
]]

local Workspace = game:GetService("Workspace")

local WARP_POINT_NAME = "WarpPoint"

local PortalLobbyWarp = {}

local function isPortalInstance(inst: Instance): boolean
	if not (inst:IsA("Model") or inst:IsA("BasePart")) then
		return false
	end
	return inst:GetAttribute("Portal") == true
end

local function collectWarpPointsByDifficulty(stageNumber: number, difficulty: number): { BasePart }
	local list: { BasePart } = {}
	for _, inst in Workspace:GetDescendants() do
		if isPortalInstance(inst) then
			local s = inst:GetAttribute("StageNumber")
			local d = inst:GetAttribute("Difficulty")
			if s == stageNumber and d == difficulty then
				local w = inst:FindFirstChild(WARP_POINT_NAME, true)
				if w and w:IsA("BasePart") then
					table.insert(list, w :: BasePart)
				end
			end
		end
	end
	return list
end

local function collectWarpPointsByTeam(stageNumber: number, team: string): { BasePart }
	local list: { BasePart } = {}
	for _, inst in Workspace:GetDescendants() do
		if isPortalInstance(inst) then
			local s = inst:GetAttribute("StageNumber")
			local t = inst:GetAttribute("Team")
			if s == stageNumber and t == team then
				local w = inst:FindFirstChild(WARP_POINT_NAME, true)
				if w and w:IsA("BasePart") then
					table.insert(list, w :: BasePart)
				end
			end
		end
	end
	return list
end

local function pickClosestWarp(warps: { BasePart }, origin: Vector3): BasePart?
	local best: BasePart? = nil
	local bestDist = math.huge
	for _, p in ipairs(warps) do
		local d = (p.Position - origin).Magnitude
		if d < bestDist then
			bestDist = d
			best = p
		end
	end
	return best
end

local function warpToParts(player: Player, warps: { BasePart }, warnLabel: string): boolean
	if not (player and player.Parent) then
		return false
	end
	local char = player.Character
	if not char or not char:IsA("Model") then
		return false
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not hrp then
		return false
	end
	if #warps == 0 then
		warn(string.format("[PortalLobbyWarp] WarpPoint 없음 (%s) player=%s", warnLabel, player.Name))
		return false
	end
	local targetPart = pickClosestWarp(warps, hrp.Position)
	if not targetPart then
		return false
	end
	local yLift = targetPart.Size.Y * 0.5 + hum.HipHeight + 0.5
	local targetCf = targetPart.CFrame * CFrame.new(0, yLift, 0)
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	char:PivotTo(targetCf)
	return true
end

--- 성공 시 true. WarpPoint 없거나 캐릭터 없으면 false.
function PortalLobbyWarp.warpPlayerToStageDifficultyWarpPoint(
	player: Player,
	stageNumber: number,
	difficulty: number
): boolean
	if typeof(stageNumber) ~= "number" or typeof(difficulty) ~= "number" then
		return false
	end
	return warpToParts(
		player,
		collectWarpPointsByDifficulty(stageNumber, difficulty),
		string.format("stage=%d diff=%d", stageNumber, difficulty)
	)
end

--- Stage2 PVP: Team("Red"|"Blue") 포탈 WarpPoint 로 이동.
--- portalNumber 가 있으면 해당 번호 포탈만 대상으로 한다.
function PortalLobbyWarp.warpPlayerToStageTeamWarpPoint(
	player: Player,
	stageNumber: number,
	team: string,
	portalNumber: number?
): boolean
	if typeof(stageNumber) ~= "number" or typeof(team) ~= "string" then
		return false
	end
	if team ~= "Red" and team ~= "Blue" then
		return false
	end
	local warps = collectWarpPointsByTeam(stageNumber, team)
	if typeof(portalNumber) == "number" then
		local filtered: { BasePart } = {}
		for _, inst in Workspace:GetDescendants() do
			if isPortalInstance(inst) then
				local s = inst:GetAttribute("StageNumber")
				local t = inst:GetAttribute("Team")
				local pn = inst:GetAttribute("PortalNumber")
				if s == stageNumber and t == team and pn == portalNumber then
					local w = inst:FindFirstChild(WARP_POINT_NAME, true)
					if w and w:IsA("BasePart") then
						table.insert(filtered, w :: BasePart)
					end
				end
			end
		end
		warps = filtered
	end
	local label = if typeof(portalNumber) == "number"
		then string.format("stage=%d team=%s portalNumber=%d", stageNumber, team, portalNumber)
		else string.format("stage=%d team=%s", stageNumber, team)
	return warpToParts(player, warps, label)
end

return PortalLobbyWarp
