--[[
	OptionHelper (shared)

	OptionData.types 조회 + StringData 포맷 치환 (RelicHelper 등에서 stat1/stat2 문장 조립용).
	마스터 데이터: ServerStorage.DataTable.OptionData
	클라이언트: DataManager.init() 시 ReplicatedStorage.DataTable.OptionData 로 복제됨
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StringHelper = require(Shared.Helpers.StringHelper)
local Types = require(Shared.Types)

local OptionHelper = {}

local runtimeCache: { [string]: Types.OptionTypeDefinition }? = nil

local function buildFallbackTypes(): { [string]: Types.OptionTypeDefinition }
	local fallback: { [string]: Types.OptionTypeDefinition } = {}
	for _, optionType in Types.OPTION_TYPES do
		fallback[optionType] = {
			stringKey = "Option_" .. optionType,
			statCount = 2,
		}
	end
	return fallback
end

local function normalizeTypes(raw: any): { [string]: Types.OptionTypeDefinition }?
	if typeof(raw) ~= "table" or typeof(raw.types) ~= "table" then
		return nil
	end

	local types: { [string]: Types.OptionTypeDefinition } = {}
	for key, value in raw.types do
		local optionType = Types.normalizeOptionType(key)
		if optionType and typeof(value) == "table" and typeof(value.stringKey) == "string" then
			local statCount = if typeof(value.statCount) == "number" then value.statCount else 1
			types[optionType] = {
				stringKey = value.stringKey,
				statCount = statCount,
			}
		end
	end

	if next(types) == nil then
		return nil
	end
	return types
end

local function loadOptionDataRaw(): any?
	if RunService:IsServer() then
		local ok, result = pcall(function()
			return require(ServerStorage:WaitForChild("DataTable"):WaitForChild("OptionData"))
		end)
		if ok then
			return result
		end
		return nil
	end

	local ok, result = pcall(function()
		return require(ReplicatedStorage:WaitForChild("DataTable"):WaitForChild("OptionData"))
	end)
	if ok then
		return result
	end
	return nil
end

local function getRuntime(): { [string]: Types.OptionTypeDefinition }
	if runtimeCache then
		return runtimeCache
	end
	local raw = loadOptionDataRaw()
	local normalized = if raw ~= nil then normalizeTypes(raw) else nil
	if normalized then
		runtimeCache = normalized
	else
		runtimeCache = buildFallbackTypes()
		warn("[OptionHelper] OptionData 없음/형식 오류 — fallback 사용 (src/datatable/OptionData.luau)")
	end
	return runtimeCache :: { [string]: Types.OptionTypeDefinition }
end

function OptionHelper.getTypeDefinition(optionType: Types.OptionType): Types.OptionTypeDefinition?
	return getRuntime()[optionType]
end

--[[
	stat2 는 statCount == 1 인 타입의 경우 nil로 넘겨도 무방 — StringHelper.format은
	템플릿에 없는 {1} 자리는 그냥 무시한다.
]]
function OptionHelper.formatText(optionType: Types.OptionType, stat1: number, stat2: number?, locale: string): string?
	local typeDef = getRuntime()[optionType]
	if not typeDef then
		return nil
	end
	local template = StringHelper.get(typeDef.stringKey, locale)
	return StringHelper.format(template, stat1, stat2)
end

return OptionHelper
