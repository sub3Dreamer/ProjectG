--[[
	임의 Model(PrimaryPart 보유, 축정렬/Orientation 0 가정)의 바닥面을 Terrain/지형에 스냅한다.
	ScaleModule.alignR15FeetToGround와 동일한 Raycast 패턴(FilterType=Exclude로 자기 자신 제외,
	위쪽에서 아래로 캐스트)을 캐릭터 전용 로직 없이 일반 Model에 맞게 재사용한 버전.

	raycastGroundY/placeModelBottomAtY로 단계를 분리해둔 것은, 호출부가 raycast 결과(히트 Y +
	히트 Instance)를 직접 검증(예: 신뢰 가능한 근처 기준 Y와 비교)한 뒤 재시도하거나 다른 Y를
	쓰기로 결정할 수 있게 하기 위함이다(램프/가드레일 등 장식물을 잘못 맞히는 경우 대응).
]]

local ModelGroundSnap = {}

-- 탐색 시작 Y(originGuess.Y)는 실제 지면과 크게 어긋나 있을 수 있다(예: 플레이어 위치 기준으로
-- 계산된 Area 중심 — 플레이어 Pivot은 지면이 아니라 대략 허리/루트 높이). 이미 지면보다 한참
-- 아래에서 아래로 쏘면 지형을 영영 못 만나므로, 위/아래 모두 넉넉하게 잡아 첫 히트를 지면으로
-- 간주한다.
local PROBE_UP_STUDS = 250
local PROBE_DOWN_STUDS = 1000

--- originGuess 근방(XZ는 그대로, Y는 originGuess.Y ± 확률범위)에서 아래로 raycast해 첫 히트의
--- Y와 히트 Instance를 반환한다. 미스 시 (nil, nil).
function ModelGroundSnap.raycastGroundY(originGuess: Vector3, excludes: { Instance }?): (number?, Instance?)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = excludes or {}

	local origin = Vector3.new(originGuess.X, originGuess.Y + PROBE_UP_STUDS, originGuess.Z)
	local result = workspace:Raycast(origin, Vector3.new(0, -(PROBE_UP_STUDS + PROBE_DOWN_STUDS), 0), rayParams)
	if not result then
		return nil, nil
	end
	return result.Position.Y, result.Instance
end

--- model.PrimaryPart의 (스케일 적용 후) 월드 바닥이 groundY에 오도록 model 전체를 Y축으로
--- 이동시킨다. PrimaryPart가 없으면 아무것도 하지 않고 false를 반환.
function ModelGroundSnap.placeModelBottomAtY(model: Model, groundY: number): boolean
	local primaryPart = model.PrimaryPart
	if not primaryPart then
		warn("[ModelGroundSnap] PrimaryPart 없음 — 스냅 스킵:", model:GetFullName())
		return false
	end

	local bottomY = primaryPart.Position.Y - primaryPart.Size.Y / 2
	local deltaY = groundY - bottomY
	if math.abs(deltaY) > 1e-3 then
		model:PivotTo(model:GetPivot() + Vector3.new(0, deltaY, 0))
	end
	return true
end

--- model.PrimaryPart 기준 바닥 Y를 계산해 그 지점에서 raycast로 찾은 지형 Y와 일치하도록 옮기는
--- 단순 편의 함수(검증 없이 raycast 결과를 그대로 신뢰). 여러 후보 표면 중 잘못된 곳(장식물 등)에
--- 맞을 위험이 있는 상황에서는 raycastGroundY로 직접 검증 후 placeModelBottomAtY를 쓸 것.
---
--- extraExcludes: model 자신 외에 추가로 무시할 Instance 목록(예: 건물 폴더).
function ModelGroundSnap.snapModelBottomToGround(model: Model, extraExcludes: { Instance }?): boolean
	local primaryPart = model.PrimaryPart
	if not primaryPart then
		warn("[ModelGroundSnap] PrimaryPart 없음 — 스냅 스킵:", model:GetFullName())
		return false
	end

	local bottomY = primaryPart.Position.Y - primaryPart.Size.Y / 2

	local excludeList = { model }
	if extraExcludes then
		for _, inst in extraExcludes do
			table.insert(excludeList, inst)
		end
	end

	local groundY = ModelGroundSnap.raycastGroundY(Vector3.new(primaryPart.Position.X, bottomY, primaryPart.Position.Z), excludeList)
	if not groundY then
		warn("[ModelGroundSnap] 바닥 Raycast 실패 — 스냅 스킵:", model:GetFullName())
		return false
	end

	return ModelGroundSnap.placeModelBottomAtY(model, groundY)
end

return ModelGroundSnap
