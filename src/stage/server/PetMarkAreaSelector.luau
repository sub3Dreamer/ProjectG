--[[
	펫 건물 마킹 시스템 순수 로직 ("펫 건물 마킹 시스템.md" 3~5장):
	- computeAreas: 플레이어 위치/레벨 기준 겹치지 않는 Area 3개(중심+반경) 생성.
	- selectBuildingForArea: Area 내부에서 Tier 우선순위 버킷으로 건물 1개 선정, 실패 시
	  Tier 무시 대체 건물 탐색(5.2/5.3)까지 시도.

	이 모듈은 엔진 인스턴스를 생성/파괴하지 않는 순수 조회 함수만 제공한다(SpeechBubbleGui 부착
	등 실제 마킹 부작용은 호출부 책임). SpeechBubbleManager가 후보 스캔~마킹 사이 yield 없이
	호출해야 동시 마킹 중복을 막을 수 있다는 불변식은 호출부(SpeechBubbleManager)가 지킨다.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local DamageableObjectStats = require(Shared.Utils.DamageableObjectStats)
local ArenaBounds = require(Shared.Utils.ArenaBounds)
local LevelXpCurve = require(Shared.Config.LevelXpCurve)

local PetMarkAreaSelector = {}

export type Area = {
	center: Vector3,
	radius: number,
}

export type Selection = {
	model: Model,
}

local MAX_RANGE_EXPANSIONS = 5
local AREA_PLACEMENT_ATTEMPTS = 20

--- 건물 Tier가 가질 수 있는 진짜 최댓값. Tier는 "구 Level"이라 플레이어 레벨과 동일한 스케일이고
--- (DamageableObjectStats.luau 상단 주석, XpHandler/CombatHandler의 level-tier 차이 계산 참고), 그
--- 최댓값은 LevelXpCurve.meta.maxLevel(현재 9)이다. PetMarkConfig.AreaByLevel의 정의 개수(8 — 레벨 9
--- 플레이어는 애초에 마킹 대상이 아니라서 Area 설정이 없을 뿐)와는 다른 값이니 절대 그걸로 대체하면
--- 안 된다 — 그러면 Tier=9인 건물이 Area 반경 안에 있어도 어떤 우선순위 버킷에도 안 걸려서, 멀쩡히
--- 근처에 있는 건물을 두고 5.2/5.3(반경 무제한 확장) 폴백으로 새어나가는 원인이 된다.
local MAX_TIER = (LevelXpCurve.meta and LevelXpCurve.meta.maxLevel) or 9

local function maxDefinedKey(t: { [number]: any }): number
	local maxKey = 0
	for key in t do
		if typeof(key) == "number" then
			maxKey = math.max(maxKey, key)
		end
	end
	return maxKey
end

--- byLevel(config.AreaByLevel)에 정의된 항목 개수 기준으로 플레이어 레벨을 클램프해 Area 설정을
--- 조회한다. 이 상한은 "플레이어 레벨별 Area 설정이 몇 개 정의돼 있는지"를 묻는 것이지 건물 Tier의
--- 상한이 아니다 — Tier 상한이 필요하면 MAX_TIER를 써야 한다(둘을 혼동한 게 과거 버그 원인).
local function levelConfigFor(level: number, byLevel: { [number]: any })
	local maxKey = maxDefinedKey(byLevel)
	if maxKey == 0 then
		return nil
	end
	local clamped = math.clamp(math.floor(level + 0.5), 1, maxKey)
	return byLevel[clamped]
end

--- 레벨 L 기준 Tier 우선순위 버킷 목록: {L-1,L,L+1} -> L+2 -> L+3 ... -> maxTier -> L-2 -> ... -> minTier
local function buildPriorityBuckets(level: number, minTier: number, maxTier: number): { { [number]: boolean } }
	local clampedLevel = math.clamp(math.floor(level + 0.5), minTier, maxTier)
	local buckets = {}
	local covered = {}

	local firstBucket = {}
	for tier = clampedLevel - 1, clampedLevel + 1 do
		if tier >= minTier and tier <= maxTier then
			firstBucket[tier] = true
			covered[tier] = true
		end
	end
	if next(firstBucket) then
		table.insert(buckets, firstBucket)
	end

	for tier = clampedLevel + 2, maxTier do
		if not covered[tier] then
			table.insert(buckets, { [tier] = true })
			covered[tier] = true
		end
	end

	for tier = clampedLevel - 2, minTier, -1 do
		if not covered[tier] then
			table.insert(buckets, { [tier] = true })
			covered[tier] = true
		end
	end

	return buckets
end

type Candidate = { model: Model, tier: number }

--- Area(중심+반경) 내부의 미마킹 건물 후보를 모두 수집한다. 이미 파괴된 건물은 modelFolders에서
--- 사라진 상태라 별도 체크가 필요 없고, 스테이지 보스는 구조적으로 이 폴더들 하위에 없다(기존
--- SpeechBubbleManager와 동일 불변식).
---
--- modelFolders는 StageMap 직계 자식 중 이름이 "Model"인 것 전부다 — 구역/Zone마다 하나씩 있을 수
--- 있어(풀맵처럼 여러 Zone을 이어붙인 맵), 그중 하나만 보면 다른 Zone의 건물을 통째로 놓친다.
local function collectCandidates(modelFolders: { Instance }, center: Vector3, radius: number): { Candidate }
	local candidates: { Candidate } = {}
	for _, modelFolder in modelFolders do
		for _, child in modelFolder:GetChildren() do
			if child:IsA("Model") and not child:FindFirstChild("SpeechBubbleGui") then
				local tier = DamageableObjectStats.tierOnModel(child :: Model)
				if tier then
					local dist = ((child :: Model):GetPivot().Position - center).Magnitude
					if dist <= radius then
						table.insert(candidates, { model = child :: Model, tier = tier })
					end
				end
			end
		end
	end
	return candidates
end

local function pickFromCandidates(candidates: { Candidate }): Selection
	local picked = candidates[math.random(1, #candidates)]
	return { model = picked.model }
end

--- 플레이어 위치/레벨 기준 Area 3개(AreaCount) 생성. Area 중심 간 최소거리는 AreaRadius*2.
--- 기본 SpawnRangeMin~Max 범위로 다 채우지 못하면 SpawnRangeMax만 배율만큼 확장(최대
--- MAX_RANGE_EXPANSIONS회)하며 계속 시도한다. 그래도 못 채우면 이번 사이클엔 그만큼만 반환.
---
--- modelFolders를 넘기면, 그 반경(AreaRadius) 안에 실제 건물이 하나도 없는 후보 위치는 거부한다
--- (selectBuildingForArea의 1차 탐색과 동일한 반경/조건 — collectCandidates 재사용). 이게 없으면
--- 플레이어가 맵 가장자리/바깥에 있을 때 Area가 맵 밖 빈 공간에 잡혀, 나중에 실제 마킹 단계가
--- 대체 건물 탐색(5.2/5.3)으로 맵 반대편의 엉뚱한 건물을 찾아내는 결과로 이어진다 — UFO가 보인
--- 자리와 실제 마커 위치가 완전히 동떨어지는 원인. modelFolders를 안 넘기면(빈 목록) 이 검증 없이
--- 기존과 동일하게 동작한다.
---
--- 아레나 벽 밖(장외 영역)까지 걸치는 후보는 제외한다(원 전체가 안쪽에 들어와야 통과) — 벽 안으로
--- 클램프해서 억지로 채우면 안 된다. 클램프는 "플레이어 근처"라는 전제를 깨고 벽을 따라 임의의
--- 위치로 밀려나므로, 근처에 건물이 없을 때 maxDist 확장과 맞물려 결국 맵 반대편 건물까지 채택하는
--- 결과를 낳는다 — 이게 바로 이 필터가 막으려는 "UFO가 플레이어와 동떨어진 곳에 뜨는" 원래 버그를
--- 그대로 재현한다. 플레이어가 벽/코너 근처라 유효 후보가 부족하면, 아래 while 루프가 areaCount(3)
--- 미만으로 끝나는 게 의도된 동작이다(그마저도 없으면 0개 — 호출부가 빈 목록을 감당한다).
function PetMarkAreaSelector.computeAreas(centerPosition: Vector3, level: number, config, modelFolders: { Instance }): { Area }
	local levelCfg = levelConfigFor(level, config.AreaByLevel)
	if not levelCfg then
		return {}
	end

	local radius = levelCfg.AreaRadius
	local minDist = levelCfg.SpawnRangeMin
	local maxDist = levelCfg.SpawnRangeMax
	local areaCount = config.AreaCount or 3
	local expandMultiplier = config.SpawnRangeExpandMultiplier or 2

	local areas: { Area } = {}
	local expansions = 0

	while #areas < areaCount and expansions <= MAX_RANGE_EXPANSIONS do
		for _ = 1, AREA_PLACEMENT_ATTEMPTS do
			if #areas >= areaCount then
				break
			end
			local angle = math.random() * math.pi * 2
			local dist = minDist + math.random() * (maxDist - minDist)
			local candidateCenter = centerPosition + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)

			local farEnough = true
			for _, existing in areas do
				if (existing.center - candidateCenter).Magnitude < radius * 2 then
					farEnough = false
					break
				end
			end

			-- 아레나 벽 밖(장외 영역)까지 걸치는 후보는 제외 — 원 전체가 안쪽에 들어와야 통과.
			if farEnough then
				farEnough = ArenaBounds.isCircleFullyInside(candidateCenter, radius)
			end

			if farEnough and #modelFolders > 0 then
				farEnough = #collectCandidates(modelFolders, candidateCenter, radius) > 0
			end

			if farEnough then
				table.insert(areas, { center = candidateCenter, radius = radius })
			end
		end

		if #areas >= areaCount then
			break
		end
		maxDist *= expandMultiplier
		expansions += 1
	end

	return areas
end

--- Area 내부에서 Tier 우선순위 버킷 순서로 건물을 선정한다(4.2/4.3). 전 버킷에 후보가 없으면
--- Tier를 무시하고 Area 중심 기준 SpawnRangeMax(배율 확장, 최대 MAX_RANGE_EXPANSIONS회)로
--- 넓혀가며 대체 건물을 찾는다(5.2/5.3). 그마저 없으면 nil(5.1 — 이 Area는 마커 없음).
---
--- 버킷 범위는 MAX_TIER(실제 Tier 최댓값)까지 커버해야 한다 — config.AreaByLevel의 정의 개수로
--- 대체하면 그 범위를 넘는 Tier의 건물은 Area 안에 멀쩡히 있어도 어떤 버킷에도 안 걸려서 곧장
--- 5.2/5.3으로 새어나간다(Area 안에 후보가 있는데도 Area 밖 건물이 마킹되는 버그였음).
function PetMarkAreaSelector.selectBuildingForArea(area: Area, level: number, modelFolders: { Instance }, config): Selection?
	local minTierBound = 1
	local maxTierBound = MAX_TIER

	local inAreaCandidates = collectCandidates(modelFolders, area.center, area.radius)
	if #inAreaCandidates > 0 then
		local buckets = buildPriorityBuckets(level, minTierBound, maxTierBound)
		for _, bucketTiers in buckets do
			local bucketCandidates: { Candidate } = {}
			for _, c in inAreaCandidates do
				if bucketTiers[c.tier] then
					table.insert(bucketCandidates, c)
				end
			end
			if #bucketCandidates > 0 then
				return pickFromCandidates(bucketCandidates)
			end
		end
	end

	-- 5.2/5.3: Tier 무시, Area 중심 기준으로 SpawnRangeMax를 확장해가며 대체 건물 탐색.
	-- (기획서는 "해당 플레이어 레벨의 SpawnRangeMax"라고만 명시하고 기준점을 특정하지 않음 —
	-- 이 Area 자체가 이미 실패했으므로 그 Area의 중심을 그대로 기준점으로 사용한다.)
	local levelCfg = levelConfigFor(level, config.AreaByLevel)
	if not levelCfg then
		return nil
	end

	local expandMultiplier = config.SpawnRangeExpandMultiplier or 2
	local radius = levelCfg.SpawnRangeMax
	for _ = 0, MAX_RANGE_EXPANSIONS do
		local substituteCandidates = collectCandidates(modelFolders, area.center, radius)
		if #substituteCandidates > 0 then
			return pickFromCandidates(substituteCandidates)
		end
		radius *= expandMultiplier
	end

	return nil
end

local OVERLAP_RESOLVE_ITERATIONS = 8

--- computeAreas는 게임플레이용 AreaRadius(건물 탐색 반경) 기준으로만 겹침을 방지한다. UFO의
--- 실제 비주얼 반경은 겹침 방지 여유분(UFO_OVERLAP_PADDING_STUDS)만큼 그보다 살짝 크므로, 그
--- 실측 반경을 알게 된 뒤 이 함수로 한 번 더 겹침을 풀어준다. items[i].center를 실제 반경 기준으로
--- 서로 밀어내며 제자리에서 수정한다(items는 {center: Vector3, radius: number} 형태 — Area
--- 자체를 넘겨도 되고, radius만 UFO 실측 반경으로 바꿔서 넘겨도 된다).
function PetMarkAreaSelector.resolveVisualOverlaps(items: { { center: Vector3, radius: number } })
	for _ = 1, OVERLAP_RESOLVE_ITERATIONS do
		local movedAny = false
		for i = 1, #items do
			for j = i + 1, #items do
				local a, b = items[i], items[j]
				local delta = b.center - a.center
				local dist = delta.Magnitude
				local minDist = a.radius + b.radius
				if dist < minDist then
					movedAny = true
					local push = (minDist - dist) / 2
					local dir = if dist > 1e-3 then delta.Unit else Vector3.new(1, 0, 0)
					a.center -= dir * push
					b.center += dir * push
				end
			end
		end
		if not movedAny then
			break
		end
	end
end

--- resolveVisualOverlaps로 밀린 결과, 플레이어(centerPosition)와 너무 가까워진 item만 밀어낸다
--- (각도는 유지). 기준은 SpawnRangeMin 자체가 아니라 `SpawnRangeMin + item.radius`다 — item.radius
--- 는 그 UFO의 실제 시각적 반경(Tier에 따라 여러 배로 커짐)이므로, 중심 거리만 minDist를
--- 만족시키면 큰 UFO는 표면/몸체가 플레이어 위치까지 침범할 수 있다. "플레이어 ↔ UFO 표면" 사이에
--- 항상 최소 SpawnRangeMin만큼 빈 공간이 남도록, UFO가 클수록 중심을 그만큼 더 멀리 배치한다.
--- 필요 최소 거리에 딱 맞춰 밀면 같은 Tier끼리는 항상 똑같은 거리로 보여 부자연스러우므로,
--- SpawnRangeMin~Max 폭만큼 랜덤한 여유를 추가로 얹는다(각 item마다 독립적으로 랜덤).
--- SpawnRangeMax 자체를 상한으로 강제하지는 않음 — 겹침을 풀기 위해서라면 원래 SpawnRangeMax보다
--- 더 멀리 밀려나는 것을 허용한다("플레이어 코앞에 스폰"이 "UFO가 조금 더 멀리 밀려남"보다 나쁜
--- 결과이기 때문).
function PetMarkAreaSelector.enforceMinSpawnDistance(items: { { center: Vector3, radius: number } }, centerPosition: Vector3, level: number, config)
	local levelCfg = levelConfigFor(level, config.AreaByLevel)
	if not levelCfg then
		return
	end
	local minDist = levelCfg.SpawnRangeMin
	local jitterRange = math.max(0, levelCfg.SpawnRangeMax - levelCfg.SpawnRangeMin)

	for _, item in items do
		local requiredDist = minDist + item.radius
		local offset = item.center - centerPosition
		local flatOffset = Vector3.new(offset.X, 0, offset.Z)
		local dist = flatOffset.Magnitude
		if dist < requiredDist then
			local pushedDist = requiredDist + math.random() * jitterRange
			local dir = if dist > 1e-3 then flatOffset.Unit else Vector3.new(1, 0, 0)
			local pushed = dir * pushedDist
			item.center = Vector3.new(centerPosition.X + pushed.X, item.center.Y, centerPosition.Z + pushed.Z)
		end
	end
end

return PetMarkAreaSelector
