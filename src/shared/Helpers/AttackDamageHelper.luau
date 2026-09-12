--[[
	AttackDamageCurve 조회 공용 헬퍼. CombatHandler(플레이어 Punch/Trample)와 PetManager(펫 공격)
	양쪽에서 동일한 공격력 계산식을 쓰기 위해 분리했다.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AttackDamageCurve = require(Shared.Config.AttackDamageCurve)
local LevelDiffCurve = require(Shared.Utils.LevelDiffCurve)

local AttackDamageHelper = {}

function AttackDamageHelper.getAttackDamageForLevel(level: number): number
	local arr = AttackDamageCurve.damageByLevel
	if typeof(arr) ~= "table" then
		return math.max(1, math.floor(level + 0.5))
	end

	local idx = math.max(1, math.floor(level + 0.5))
	local v = arr[tostring(idx)] or arr[idx]
	if typeof(v) == "number" and v == v and v > 0 then
		return math.floor(v + 0.5)
	end

	local maxLevel = idx
	local meta = AttackDamageCurve.meta
	if typeof(meta) == "table" and typeof(meta.maxLevel) == "number" then
		maxLevel = math.max(1, math.floor(meta.maxLevel))
	end

	local fallback = arr[tostring(maxLevel)] or arr[maxLevel]
	if typeof(fallback) == "number" and fallback == fallback and fallback > 0 then
		return math.floor(fallback + 0.5)
	end

	return math.max(1, idx)
end

--- 레벨차(diff = playerLevel - targetLevel) 기준 데미지 배율 조회.
--- 정의된 범위(-9~9) 밖이면 가까운 끝 값으로 고정(diff<=-9 → -9행, diff>=9 → 9행).
function AttackDamageHelper.getLevelGapDamageMultiplier(playerLevel: number, targetLevel: number): number
	local diff = playerLevel - targetLevel
	return LevelDiffCurve.lookupMultiplier(AttackDamageCurve.damageMultiplierByLevelDiff, diff, 1)
end

return AttackDamageHelper
