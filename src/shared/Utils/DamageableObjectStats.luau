--[[
	파괴 가능 Model 공통 stat:
	- Tier (구 Level)
	- HitPoint (JSON config: easy/normal/hard) → CurrentHitPoint / MaxHitPoint 런타임
	- XP (파괴 보상)
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameSettings = require(Shared.Config.GameSettings)
local DifficultyConfig = require(Shared.Config.DifficultyConfig)

local DamageableObjectStats = {}

local function combatCfg()
	return GameSettings.Combat
end

function DamageableObjectStats.getDifficultyKey(difficulty: number): string
	return DifficultyConfig.statKeys[difficulty] or "normal"
end

local function parsePositiveInt(v: any): number?
	if typeof(v) == "number" and v == v and v >= 1 then
		return math.floor(v + 0.5)
	end
	if typeof(v) == "string" then
		local n = tonumber(v)
		if n and n >= 1 then
			return math.floor(n + 0.5)
		end
	end
	return nil
end

local function parsePositiveNumber(v: any): number?
	if typeof(v) == "number" and v == v and v > 0 then
		return v
	end
	if typeof(v) == "string" then
		local n = tonumber(v)
		if n and n == n and n > 0 then
			return n
		end
	end
	return nil
end

local function readAttributeOrChildValue(model: Model, attrName: string): any
	local v = model:GetAttribute(attrName)
	if v ~= nil then
		return v
	end
	local child = model:FindFirstChild(attrName)
	if child and child:IsA("NumberValue") then
		return child.Value
	end
	if child and child:IsA("IntValue") then
		return child.Value
	end
	if child and child:IsA("StringValue") then
		return child.Value
	end
	return nil
end

function DamageableObjectStats.parseMaxHitPointFromConfig(raw: any, difficulty: number): number?
	local direct = parsePositiveNumber(raw)
	if direct then
		return direct
	end

	if typeof(raw) ~= "string" then
		return nil
	end

	local trimmed = raw:match("^%s*(.-)%s*$")
	if trimmed == "" then
		return nil
	end

	local asNumber = tonumber(trimmed)
	if asNumber and asNumber > 0 then
		return asNumber
	end

	if trimmed:sub(1, 1) ~= "{" then
		return nil
	end

	local ok, tbl = pcall(function()
		return HttpService:JSONDecode(trimmed)
	end)
	if not ok or typeof(tbl) ~= "table" then
		return nil
	end

	local key = DamageableObjectStats.getDifficultyKey(difficulty)
	local v = tbl[key]
	if typeof(v) == "number" and v == v and v > 0 then
		return v
	end
	return nil
end

function DamageableObjectStats.tierOnModel(model: Model): number?
	local cfg = combatCfg()
	local attrName = cfg.TierAttributeName or "Tier"
	return parsePositiveInt(readAttributeOrChildValue(model, attrName))
end

function DamageableObjectStats.xpRewardOnModel(model: Model): number?
	local cfg = combatCfg()
	local attrName = cfg.RewardXpAttributeName or "XP"
	local v = readAttributeOrChildValue(model, attrName)
	if typeof(v) == "number" and v == v and v > 0 then
		return math.floor(v + 0.5)
	end
	if typeof(v) == "string" then
		local n = tonumber(v)
		if n and n > 0 then
			return math.floor(n + 0.5)
		end
	end
	return nil
end

function DamageableObjectStats.currentHitPointOnModel(model: Model): number?
	local cfg = combatCfg()
	local attrName = cfg.CurrentHitPointAttributeName or "CurrentHitPoint"
	local v = model:GetAttribute(attrName)
	if typeof(v) == "number" and v == v and v >= 0 then
		return v
	end
	return nil
end

function DamageableObjectStats.hasDamageableConfig(model: Model): boolean
	local cfg = combatCfg()
	local hpConfigName = cfg.HitPointConfigAttributeName or "HitPoint"
	local raw = readAttributeOrChildValue(model, hpConfigName)
	for _, diff in ipairs({ 1, 2, 3 }) do
		if DamageableObjectStats.parseMaxHitPointFromConfig(raw, diff) ~= nil then
			return true
		end
	end
	return DamageableObjectStats.currentHitPointOnModel(model) ~= nil
end

function DamageableObjectStats.isDamageableModel(model: Model): boolean
	if not model:IsA("Model") then
		return false
	end
	local hp = DamageableObjectStats.currentHitPointOnModel(model)
	if hp ~= nil and hp > 0 then
		return true
	end
	return DamageableObjectStats.hasDamageableConfig(model)
end

function DamageableObjectStats.initRuntimeStats(model: Model, difficulty: number): boolean
	if not model:IsA("Model") then
		return false
	end

	local cfg = combatCfg()
	local hpConfigName = cfg.HitPointConfigAttributeName or "HitPoint"
	local currentName = cfg.CurrentHitPointAttributeName or "CurrentHitPoint"
	local maxName = cfg.MaxHitPointAttributeName or "MaxHitPoint"

	local raw = readAttributeOrChildValue(model, hpConfigName)
	local maxHp = DamageableObjectStats.parseMaxHitPointFromConfig(raw, difficulty)
	if not maxHp then
		return false
	end

	maxHp = math.floor(maxHp + 0.5)
	model:SetAttribute(maxName, maxHp)
	model:SetAttribute(currentName, maxHp)
	return true
end

function DamageableObjectStats.resolveAllInWorkspace(root: Instance?, difficulty: number): number
	local container = root or workspace
	local count = 0
	for _, inst in container:GetDescendants() do
		if inst:IsA("Model") and DamageableObjectStats.initRuntimeStats(inst, difficulty) then
			count += 1
		end
	end
	return count
end

--- HitPoint 설정은 있으나 현재 difficulty로 max HP를 못 읽은 Model 샘플을 warn (최대 maxSamples건)
function DamageableObjectStats.warnUnresolvedDamageables(root: Instance?, difficulty: number, maxSamples: number?)
	local container = root or workspace
	local cap = maxSamples or 5
	local cfg = combatCfg()
	local hpConfigName = cfg.HitPointConfigAttributeName or "HitPoint"
	local diffKey = DamageableObjectStats.getDifficultyKey(difficulty)
	local samples = 0

	for _, inst in container:GetDescendants() do
		if not inst:IsA("Model") then
			continue
		end
		if DamageableObjectStats.currentHitPointOnModel(inst) ~= nil then
			continue
		end
		local raw = readAttributeOrChildValue(inst, hpConfigName)
		if raw == nil then
			continue
		end
		if DamageableObjectStats.parseMaxHitPointFromConfig(raw, difficulty) ~= nil then
			continue
		end

		samples += 1
		if samples <= cap then
			warn(
				"[DamageableObjectStats] HitPoint 미해석:",
				inst:GetFullName(),
				"(difficulty=",
				difficulty,
				"/",
				diffKey,
				") raw=",
				tostring(raw)
			)
		end
	end

	if samples > cap then
		warn("[DamageableObjectStats] … 외", samples - cap, "개 Model 동일 원인")
	elseif samples == 0 then
		local map = workspace:FindFirstChild("StageMap")
		if map then
			warn(
				"[DamageableObjectStats] resolve 0 — StageMap 하위에 HitPoint Attribute가 있는 Model이 없습니다.",
				map:GetFullName()
			)
		else
			warn("[DamageableObjectStats] resolve 0 — Workspace.StageMap 없음(ServerStorage.StageMap 확인)")
		end
	end
end

return DamageableObjectStats
