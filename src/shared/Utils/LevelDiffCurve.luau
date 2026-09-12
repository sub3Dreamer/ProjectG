--[[
	레벨차(diff = 캐릭터 레벨 - 대상 Tier) 기준 배율 테이블 공용 조회.
	AttackDamageCurve.damageMultiplierByLevelDiff / LevelXpCurve.xpMultiplierByLevelDiff처럼
	[diff] = 배율 형태로 정의된 테이블에서, 정의된 범위 밖의 diff는 가까운 끝 값(diff가 범위보다
	작으면 최소 키, 크면 최대 키)으로 고정해 조회한다.
]]

local LevelDiffCurve = {}

--- diffTable이 없거나 비어 있으면 fallback(기본 1)을 반환한다.
function LevelDiffCurve.lookupMultiplier(diffTable: { [number]: number }?, diff: number, fallback: number?): number
	if typeof(diffTable) ~= "table" then
		return fallback or 1
	end

	local minKey, maxKey = math.huge, -math.huge
	for k in pairs(diffTable) do
		local nk: number? = nil
		if typeof(k) == "number" then
			nk = k
		elseif typeof(k) == "string" then
			nk = tonumber(k)
		end
		if nk ~= nil and nk == nk then
			minKey = math.min(minKey, nk)
			maxKey = math.max(maxKey, nk)
		end
	end

	if minKey == math.huge then
		return fallback or 1
	end

	local clampedDiff = math.clamp(math.floor(diff + 0.5), minKey, maxKey)
	local v = diffTable[clampedDiff] or diffTable[tostring(clampedDiff)]
	if typeof(v) ~= "number" or v ~= v or v < 0 then
		return fallback or 1
	end

	return v
end

return LevelDiffCurve
