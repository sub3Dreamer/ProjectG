--[[
	타격 VFX 가시성: 카메라→스폰 레이로 대상 표면 위치를 구하고, 파티클 ZOffset margin을 반환.
	targetModel이 있으면 해당 모델만 hit; 없으면 로컬 캐릭터 제외 월드 레이.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameSettings = require(Shared.Config.GameSettings)

local HitFxVisibility = {}

local function scaledSurfaceOffset(scale: number): number
	local c = GameSettings.Combat
	local base = c.HitFxSurfaceOffset
	if typeof(base) ~= "number" or base ~= base then
		base = 0.2
	end
	if typeof(scale) ~= "number" or scale ~= scale or scale <= 0 then
		return base
	end
	return base * scale
end

local function normalizedScale(scale: number): number
	if typeof(scale) ~= "number" or scale ~= scale or scale <= 0 then
		return 1
	end
	return scale
end

local function scaledZOffsetMargin(scale: number): number
	local c = GameSettings.Combat
	local base = c.HitFxZOffsetMargin
	if typeof(base) ~= "number" or base ~= base then
		base = 2
	end
	local perScale = c.HitFxZOffsetMarginPerScale
	if typeof(perScale) ~= "number" or perScale ~= perScale then
		perScale = 0.2
	end
	return base + normalizedScale(scale) * perScale
end

local function scaledZOffsetMax(scale: number): number
	local c = GameSettings.Combat
	local baseMax = c.HitFxZOffsetMax
	if typeof(baseMax) ~= "number" or baseMax ~= baseMax then
		baseMax = 40
	end
	local perScale = c.HitFxZOffsetMaxPerScale
	if typeof(perScale) ~= "number" or perScale ~= perScale then
		perScale = 3
	end
	local s = normalizedScale(scale)
	return math.max(baseMax, s * perScale)
end

local function scaledMinCameraDistance(scale: number): number
	local c = GameSettings.Combat
	local base = c.HitFxMinCameraDistance
	if typeof(base) ~= "number" or base ~= base then
		base = 4
	end
	return base * normalizedScale(scale)
end

--- 카메라로부터 minDist 이상 떨어지도록 pos를 camPos~pos 방향선상에서 밀어냄.
--- 근접 처치/타격 시 레이캐스트가 카메라 코앞 면에 스냅되면, 실제 스케일과 무관하게
--- 원근법 때문에 이펙트가 비정상적으로 커 보이는 문제를 막기 위한 안전장치.
local function ensureMinCameraDistance(camPos: Vector3, pos: Vector3, minDist: number): Vector3
	if typeof(minDist) ~= "number" or minDist ~= minDist or minDist <= 0 then
		return pos
	end
	local delta = pos - camPos
	local dist = delta.Magnitude
	if dist >= minDist then
		return pos
	end
	if dist < 1e-4 then
		local cam = Workspace.CurrentCamera
		local lookVector = cam and cam.CFrame.LookVector or Vector3.new(0, 0, -1)
		return camPos + lookVector * minDist
	end
	return camPos + (delta / dist) * minDist
end

function HitFxVisibility.resolve(spawnCf: CFrame, targetModel: Model?, scale: number): (CFrame, number)
	local surfaceOffset = scaledSurfaceOffset(scale)
	local zMargin = scaledZOffsetMargin(scale)
	local zMax = scaledZOffsetMax(scale)
	local minCameraDistance = scaledMinCameraDistance(scale)

	local cam = Workspace.CurrentCamera
	if not cam then
		return spawnCf, zMargin
	end

	local spawnPos = spawnCf.Position
	local camPos = cam.CFrame.Position
	local toSpawn = spawnPos - camPos
	local dist = toSpawn.Magnitude
	if dist < 0.01 then
		return CFrame.new(ensureMinCameraDistance(camPos, spawnPos, minCameraDistance)), zMargin
	end

	if targetModel and targetModel.Parent then
		local includeParams = RaycastParams.new()
		includeParams.FilterType = Enum.RaycastFilterType.Include
		includeParams.FilterDescendantsInstances = { targetModel }

		local surfaceHit = Workspace:Raycast(camPos, toSpawn, includeParams)
		if surfaceHit then
			local visiblePos = surfaceHit.Position + surfaceHit.Normal * surfaceOffset
			visiblePos = ensureMinCameraDistance(camPos, visiblePos, minCameraDistance)
			return CFrame.new(visiblePos), zMargin
		end

		local dirToCam = (camPos - spawnPos).Unit
		local innerHit = Workspace:Raycast(spawnPos, dirToCam * dist, includeParams)
		if innerHit then
			local depth = (innerHit.Position - spawnPos).Magnitude
			return spawnCf, math.clamp(depth + zMargin, zMargin, zMax)
		end
	end

	local excludeParams = RaycastParams.new()
	excludeParams.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	local localChar = Players.LocalPlayer and Players.LocalPlayer.Character
	if localChar then
		table.insert(exclude, localChar)
	end
	excludeParams.FilterDescendantsInstances = exclude

	local worldHit = Workspace:Raycast(camPos, toSpawn, excludeParams)
	if worldHit then
		local visiblePos = worldHit.Position + worldHit.Normal * surfaceOffset
		visiblePos = ensureMinCameraDistance(camPos, visiblePos, minCameraDistance)
		return CFrame.new(visiblePos), zMargin
	end

	return spawnCf, zMargin
end

function HitFxVisibility.resolveAttack(
	spawnCf: CFrame,
	targetModel: Model?,
	scale: number,
	maxHeadY: number?
): (CFrame, number)
	if typeof(maxHeadY) == "number" and maxHeadY == maxHeadY then
		local p = spawnCf.Position
		spawnCf = CFrame.new(Vector3.new(p.X, math.min(p.Y, maxHeadY), p.Z))
	end
	return HitFxVisibility.resolve(spawnCf, targetModel, scale)
end

local function raycastGroundAtXZ(x: number, z: number, rayStartY: number, downDist: number): RaycastResult?
	local origin = Vector3.new(x, rayStartY, z)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	local localChar = Players.LocalPlayer and Players.LocalPlayer.Character
	if localChar then
		table.insert(exclude, localChar)
	end
	params.FilterDescendantsInstances = exclude

	return Workspace:Raycast(origin, Vector3.new(0, -downDist, 0), params)
end

function HitFxVisibility.resolveTrample(spawnCf: CFrame, targetModel: Model?, scale: number): (CFrame, number)
	local c = GameSettings.Combat
	local surfaceOffset = scaledSurfaceOffset(scale)
	local zMargin = scaledZOffsetMargin(scale)

	local pos = spawnCf.Position
	local rayUp = c.HitFxTrampleGroundRayUpStuds
	if typeof(rayUp) ~= "number" or rayUp ~= rayUp then
		rayUp = 50
	end
	local rayStartY = pos.Y + rayUp * math.max(1, scale)

	if targetModel and targetModel.Parent then
		local ok, bboxCf, bboxSize = pcall(function()
			return targetModel:GetBoundingBox()
		end)
		if ok and typeof(bboxCf) == "CFrame" and typeof(bboxSize) == "Vector3" then
			local bboxTopY = bboxCf.Position.Y + bboxSize.Y * 0.5
			rayStartY = math.max(rayStartY, bboxTopY + 10)
		end
	end

	local downDist = rayStartY + 2000
	local hit = raycastGroundAtXZ(pos.X, pos.Z, rayStartY, downDist)
	if hit then
		local groundPos = hit.Position + hit.Normal * surfaceOffset
		return CFrame.new(groundPos), zMargin
	end

	return HitFxVisibility.resolve(spawnCf, targetModel, scale)
end

return HitFxVisibility
