--[[
	PortalLobbyWarp (shared, 서버·클라 모두 사용 가능)

	로비 Workspace 에서 Portal=true 이고 StageNumber/Difficulty 가 일치하는 포탈들의
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

local function collectWarpPoints(stageNumber: number, difficulty: number): { BasePart }
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

--- 성공 시 true. WarpPoint 없거나 캐릭터 없으면 false.
function PortalLobbyWarp.warpPlayerToStageDifficultyWarpPoint(
	player: Player,
	stageNumber: number,
	difficulty: number
): boolean
	if typeof(stageNumber) ~= "number" or typeof(difficulty) ~= "number" then
		return false
	end
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

	local warps = collectWarpPoints(stageNumber, difficulty)
	if #warps == 0 then
		warn(
			string.format(
				"[PortalLobbyWarp] WarpPoint 없음 (stage=%d diff=%d) player=%s",
				stageNumber,
				difficulty,
				player.Name
			)
		)
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

return PortalLobbyWarp
