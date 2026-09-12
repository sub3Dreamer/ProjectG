--[[
	StageHelper (shared)

	StageData.stages / clearRewardByDifficulty 조회 (스테이지 이름/제한시간/클리어 보상).
	마스터 데이터: ServerStorage.DataTable.StageData
	클라이언트: DataManager.init() 시 ReplicatedStorage.DataTable.StageData 로 복제됨
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StringHelper = require(Shared.Helpers.StringHelper)
local Types = require(Shared.Types)

local StageHelper = {}

local DEFAULT_TIME_LIMIT_SEC = 300
local DEFAULT_NAME_KEY = "Stage_Unknown_Name"

local DEFAULT_STAGE: Types.StageDefinition = {
	stageNumber = 0,
	nameKey = DEFAULT_NAME_KEY,
	timeLimitSec = DEFAULT_TIME_LIMIT_SEC,
}

local runtimeCache: {
	stages: { [number]: Types.StageDefinition },
	clearRewardByDifficulty: { [number]: { Types.StageClearRewardEntry } },
}? = nil

local function normalizeClearReward(raw: any): { Types.StageClearRewardEntry }
	local reward: { Types.StageClearRewardEntry } = {}
	if typeof(raw) ~= "table" then
		return reward
	end
	for _, entry in raw do
		if typeof(entry) == "table" then
			local currencyType = Types.normalizeCurrencyType(entry.currencyType)
			local amount = if typeof(entry.amount) == "number" and entry.amount > 0 then entry.amount else nil
			if currencyType and amount then
				table.insert(reward, { currencyType = currencyType, amount = math.floor(amount) })
			end
		end
	end
	return reward
end

local function normalizeStageDefinition(raw: any, stageNumber: number): Types.StageDefinition?
	if typeof(raw) ~= "table" then
		return nil
	end
	local nameKey = if typeof(raw.nameKey) == "string" and raw.nameKey ~= "" then raw.nameKey else DEFAULT_NAME_KEY
	local timeLimitSec = if typeof(raw.timeLimitSec) == "number" and raw.timeLimitSec > 0
		then math.floor(raw.timeLimitSec)
		else DEFAULT_TIME_LIMIT_SEC
	local mapImageAssetId = if typeof(raw.mapImageAssetId) == "string" and raw.mapImageAssetId ~= ""
		then raw.mapImageAssetId
		else nil
	return {
		stageNumber = stageNumber,
		nameKey = nameKey,
		timeLimitSec = timeLimitSec,
		mapImageAssetId = mapImageAssetId,
	}
end

local function normalizeStages(raw: any): { [number]: Types.StageDefinition }
	local stages: { [number]: Types.StageDefinition } = {}
	if typeof(raw) ~= "table" then
		return stages
	end
	for key, value in raw do
		local stageNumber = if typeof(key) == "number" then key else tonumber(key)
		if typeof(stageNumber) == "number" and stageNumber == stageNumber and stageNumber >= 1 then
			local def = normalizeStageDefinition(value, math.floor(stageNumber))
			if def then
				stages[math.floor(stageNumber)] = def
			end
		end
	end
	return stages
end

local function normalizeClearRewardByDifficulty(raw: any): { [number]: { Types.StageClearRewardEntry } }
	local byDifficulty: { [number]: { Types.StageClearRewardEntry } } = {}
	if typeof(raw) ~= "table" then
		return byDifficulty
	end
	for key, value in raw do
		local difficulty = if typeof(key) == "number" then key else tonumber(key)
		if typeof(difficulty) == "number" and difficulty == difficulty and difficulty >= 1 then
			byDifficulty[math.floor(difficulty)] = normalizeClearReward(value)
		end
	end
	return byDifficulty
end

local function loadStageDataRaw(): any?
	if RunService:IsServer() then
		local ok, result = pcall(function()
			return require(ServerStorage:WaitForChild("DataTable"):WaitForChild("StageData"))
		end)
		if ok then
			return result
		end
		return nil
	end

	local ok, result = pcall(function()
		return require(ReplicatedStorage:WaitForChild("DataTable"):WaitForChild("StageData"))
	end)
	if ok then
		return result
	end
	return nil
end

local function getRuntime(): {
	stages: { [number]: Types.StageDefinition },
	clearRewardByDifficulty: { [number]: { Types.StageClearRewardEntry } },
}
	if runtimeCache then
		return runtimeCache
	end

	local raw = loadStageDataRaw()
	if typeof(raw) ~= "table" then
		warn("[StageHelper] StageData 없음/형식 오류 — 기본값 사용 (src/datatable/StageData.luau)")
		raw = {}
	end

	runtimeCache = {
		stages = normalizeStages(raw.stages),
		clearRewardByDifficulty = normalizeClearRewardByDifficulty(raw.clearRewardByDifficulty),
	}
	return runtimeCache :: any
end

function StageHelper.getStage(stageNumber: number?): Types.StageDefinition
	if stageNumber then
		local def = getRuntime().stages[stageNumber]
		if def then
			return def
		end
	end
	return DEFAULT_STAGE
end

function StageHelper.getDisplayName(stageNumber: number?, locale: string): string
	return StringHelper.get(StageHelper.getStage(stageNumber).nameKey, locale)
end

function StageHelper.getTimeLimitSec(stageNumber: number?): number
	return StageHelper.getStage(stageNumber).timeLimitSec
end

function StageHelper.getMapImageAssetId(stageNumber: number?): string?
	return StageHelper.getStage(stageNumber).mapImageAssetId
end

function StageHelper.getClearReward(difficulty: number?): { Types.StageClearRewardEntry }
	if difficulty then
		return getRuntime().clearRewardByDifficulty[difficulty] or {}
	end
	return {}
end

return StageHelper
