--[[
	StringHelper (shared)

	StringData 조회 및 {0} 플레이스홀더 치환.
	마스터 데이터: ServerStorage.DataTable.StringData
	클라이언트: DataManager.init() 시 ReplicatedStorage.DataTable.StringData 로 복제됨
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DataManager = require(Shared.Managers.DataManager)

local StringHelper = {}

local stringDataCache: any = nil

local SECONDS_PER_MINUTE = 60
local SECONDS_PER_HOUR = 3600
local SECONDS_PER_DAY = 86400

local function getStringData()
	if stringDataCache then
		return stringDataCache
	end

	if RunService:IsServer() then
		local raw = DataManager.getStringDataRaw()
		if raw then
			stringDataCache = raw
			return stringDataCache
		end
		stringDataCache = require(ServerStorage:WaitForChild("DataTable"):WaitForChild("StringData"))
		return stringDataCache
	end

	stringDataCache = require(ReplicatedStorage:WaitForChild("DataTable"):WaitForChild("StringData"))
	return stringDataCache
end

function StringHelper.get(key: string, locale: string): string
	local row = getStringData().strings[key]
	if not row then
		return key
	end
	local localized = row[locale]
	if typeof(localized) == "string" then
		return localized
	end
	if typeof(row.kr) == "string" then
		return row.kr
	end
	return key
end

function StringHelper.format(template: string, ...): string
	local args = { ... }
	return (template:gsub("{(%d+)}", function(index: string): string
		local i = tonumber(index)
		if i == nil then
			return "{" .. index .. "}"
		end
		local value = args[i + 1]
		if value == nil then
			return "{" .. index .. "}"
		end
		return tostring(value)
	end))
end

function StringHelper.formatRemainTimeValue(remainingSec: number, locale: string): string
	local remaining = math.max(0, remainingSec)
	if remaining >= SECONDS_PER_DAY then
		return StringHelper.format(
			StringHelper.get("Time_Day_Format", locale),
			math.floor(remaining / SECONDS_PER_DAY)
		)
	end
	if remaining >= SECONDS_PER_HOUR then
		return StringHelper.format(
			StringHelper.get("Time_Hour_Format", locale),
			math.floor(remaining / SECONDS_PER_HOUR)
		)
	end
	if remaining >= SECONDS_PER_MINUTE then
		return StringHelper.format(
			StringHelper.get("Time_Minute_Format", locale),
			math.floor(remaining / SECONDS_PER_MINUTE)
		)
	end
	return StringHelper.format(
		StringHelper.get("Time_Second_Format", locale),
		math.floor(remaining)
	)
end

function StringHelper.formatRemainTimeLabel(remainingSec: number, locale: string): string
	return StringHelper.format(
		StringHelper.get("TxtRemainTime", locale),
		StringHelper.formatRemainTimeValue(remainingSec, locale)
	)
end

return StringHelper
