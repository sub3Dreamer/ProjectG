--[[
	PortalWarp (lobby client)

	포털 모델(Portal=true, StageNumber, Difficulty) 하위의 WarpPoint(BasePart)로
	로컬 플레이어 캐릭터를 순간이동한다. 동일 stage/diff 포털이 여러 개면
	현재 HumanoidRootPart와 가장 가까운 WarpPoint를 고른다.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local WARP_POINT_NAME = "WarpPoint"

local PortalWarp = {}

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

--- stage/diff에 맞는 WarpPoint로 로컬 플레이어를 이동 (없으면 경고만).
function PortalWarp.warpLocalPlayerToMatch(stageNumber: number, difficulty: number)
	if typeof(stageNumber) ~= "number" or typeof(difficulty) ~= "number" then
		return
	end

	local player = Players.LocalPlayer
	local char = player.Character
	if not char then
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not hrp then
		return
	end

	local warps = collectWarpPoints(stageNumber, difficulty)
	if #warps == 0 then
		warn(
			string.format(
				"[PortalWarp] WarpPoint 없음 (stage=%d diff=%d) — Workspace 포털 모델에 %s(BasePart) 확인",
				stageNumber,
				difficulty,
				WARP_POINT_NAME
			)
		)
		return
	end

	local targetPart = pickClosestWarp(warps, hrp.Position)
	if not targetPart then
		return
	end

	local yLift = targetPart.Size.Y * 0.5 + hum.HipHeight + 0.5
	local targetCf = targetPart.CFrame * CFrame.new(0, yLift, 0)

	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero

	if char:IsA("Model") then
		(char :: Model):PivotTo(targetCf)
	else
		hrp.CFrame = targetCf
	end
end

return PortalWarp
