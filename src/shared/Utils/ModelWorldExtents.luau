--[[
	Model:GetBoundingBox()는 PrimaryPart 회전이 반영된 OBB를 반환하므로, 회전된 모델에서는
	실제 월드 축 기준 높이/너비/중심과 다를 수 있다. 이 모듈은 모든 BasePart의 8코너를
	world space에서 직접 스캔해, 회전에 관계없이 정확한 월드 축 정렬(AABB) 크기·중심을 계산한다.
]]

local ModelWorldExtents = {}

export type Extents = {
	sizeX: number,
	sizeY: number,
	sizeZ: number,
	topY: number,
	centerX: number,
	centerZ: number,
}

function ModelWorldExtents.compute(model: Model): Extents
	local minX, maxX = math.huge, -math.huge
	local minY, maxY = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local cf = part.CFrame
			local hs = part.Size / 2
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local corner = cf * Vector3.new(hs.X * sx, hs.Y * sy, hs.Z * sz)
						minX = math.min(minX, corner.X)
						maxX = math.max(maxX, corner.X)
						minY = math.min(minY, corner.Y)
						maxY = math.max(maxY, corner.Y)
						minZ = math.min(minZ, corner.Z)
						maxZ = math.max(maxZ, corner.Z)
					end
				end
			end
		end
	end

	if minX == math.huge then
		return { sizeX = 0, sizeY = 0, sizeZ = 0, topY = 0, centerX = 0, centerZ = 0 }
	end

	return {
		sizeX = maxX - minX,
		sizeY = maxY - minY,
		sizeZ = maxZ - minZ,
		topY = maxY,
		centerX = (minX + maxX) / 2,
		centerZ = (minZ + maxZ) / 2,
	}
end

--- compute()와 동일하지만 Transparency>=1(완전 투명, 예: 공격판정용 히트박스 파츠)인 파츠는 제외.
--- 보이는 파츠가 하나도 없으면 nil(호출부가 기존 로직으로 폴백할 수 있도록).
function ModelWorldExtents.computeVisible(model: Model): Extents?
	local minX, maxX = math.huge, -math.huge
	local minY, maxY = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local transparency = part.Transparency
			local isVisible = typeof(transparency) ~= "number" or transparency ~= transparency or transparency < 1
			if isVisible then
				local cf = part.CFrame
				local hs = part.Size / 2
				for sx = -1, 1, 2 do
					for sy = -1, 1, 2 do
						for sz = -1, 1, 2 do
							local corner = cf * Vector3.new(hs.X * sx, hs.Y * sy, hs.Z * sz)
							minX = math.min(minX, corner.X)
							maxX = math.max(maxX, corner.X)
							minY = math.min(minY, corner.Y)
							maxY = math.max(maxY, corner.Y)
							minZ = math.min(minZ, corner.Z)
							maxZ = math.max(maxZ, corner.Z)
						end
					end
				end
			end
		end
	end

	if minX == math.huge then
		return nil
	end

	return {
		sizeX = maxX - minX,
		sizeY = maxY - minY,
		sizeZ = maxZ - minZ,
		topY = maxY,
		centerX = (minX + maxX) / 2,
		centerZ = (minZ + maxZ) / 2,
	}
end

--- computeVisible()의 집계 중심(centerX/centerZ)은 파츠들이 흩어진 모델에서 실제 지오메트리가
--- 없는 빈 공간을 가리킬 수 있다(예: BillboardGui Adornee용 anchor 배치 시 바닥에 깔리는 문제).
--- 대신 실제로 보이는(Transparency<1) 파츠 중 world Y 최상단인 것을 직접 찾아 반환한다 —
--- 이 Part 자체를 Adornee로 쓰면 항상 실제 지오메트리 위에 위치가 고정된다.
function ModelWorldExtents.findTopVisiblePart(model: Model): (BasePart?, number?)
	local bestPart: BasePart? = nil
	local bestTopY = -math.huge

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local transparency = part.Transparency
			local isVisible = typeof(transparency) ~= "number" or transparency ~= transparency or transparency < 1
			if isVisible then
				local cf = part.CFrame
				local hs = part.Size / 2
				local partTopY = -math.huge
				for sx = -1, 1, 2 do
					for sy = -1, 1, 2 do
						for sz = -1, 1, 2 do
							local corner = cf * Vector3.new(hs.X * sx, hs.Y * sy, hs.Z * sz)
							if corner.Y > partTopY then
								partTopY = corner.Y
							end
						end
					end
				end
				if partTopY > bestTopY then
					bestTopY = partTopY
					bestPart = part
				end
			end
		end
	end

	if not bestPart then
		return nil, nil
	end
	return bestPart, bestTopY
end

return ModelWorldExtents
