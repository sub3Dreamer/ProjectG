--[[
	GameSettings.ArenaWalls(사각형 경계) 기준 원(circle)이 플레이 가능 영역 안에 있는지 판정한다.
	이 프로젝트에는 voxel Terrain이 없고 StageMap이 단일 Part라, "장외 영역" 판정 기준은
	StageArenaWalls.ensureOnce()가 벽을 세우는 그 경계(GameSettings.ArenaWalls)뿐이다.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameSettings = require(Shared.Config.GameSettings)

local ArenaBounds = {}

local function bounds(): (Vector3?, number?, number?)
	local cfg = GameSettings.ArenaWalls
	if typeof(cfg) ~= "table" then
		return nil
	end
	local center = cfg.Center
	local hx = tonumber(cfg.HalfExtentsX)
	local hz = tonumber(cfg.HalfExtentsZ)
	if typeof(center) ~= "Vector3" or not hx or not hz then
		return nil
	end
	return center, hx, hz
end

--- position(XZ 평면)을 중심으로 한 반지름 radius의 원이 아레나 벽 안쪽에 완전히 들어오는지.
--- GameSettings.ArenaWalls가 없거나 파싱 실패하면 제한 없이 통과(true)시킨다.
function ArenaBounds.isCircleFullyInside(position: Vector3, radius: number): boolean
	local center, hx, hz = bounds()
	if not center then
		return true
	end
	return math.abs(position.X - center.X) + radius <= hx and math.abs(position.Z - center.Z) + radius <= hz
end

--- 원이 아레나 벽을 넘어가지 않도록 X/Z를 각각 클램프한 새 위치를 반환한다(Y는 그대로 유지).
--- radius가 hx/hz보다 크면(원이 아레나 자체보다 큰 극단적 경우) center.X/center.Z로 수렴한다.
function ArenaBounds.clampCircleInside(position: Vector3, radius: number): Vector3
	local center, hx, hz = bounds()
	if not center then
		return position
	end

	local minX, maxX = center.X - hx + radius, center.X + hx - radius
	local minZ, maxZ = center.Z - hz + radius, center.Z + hz - radius
	if minX > maxX then
		minX, maxX = center.X, center.X
	end
	if minZ > maxZ then
		minZ, maxZ = center.Z, center.Z
	end

	local clampedX = math.clamp(position.X, minX, maxX)
	local clampedZ = math.clamp(position.Z, minZ, maxZ)
	return Vector3.new(clampedX, position.Y, clampedZ)
end

return ArenaBounds
