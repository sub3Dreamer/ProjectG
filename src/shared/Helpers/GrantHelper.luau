--[[
	GrantHelper (shared)

	마스터 데이터: DataManager.getGrantDataRaw() (서버) / ServerStorage.DataTable.GrantData
	플레이어 로드 직후 DataManager가 applyPendingCampaigns 호출.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)

local GrantHelper = {}

export type GrantItemEntry = Types.GrantItemEntry
export type GrantCampaignDefinition = Types.GrantCampaignDefinition
export type GrantDataSource = Types.GrantDataSource

local GRANT_DATA_MODULE_NAME = "GrantData"

local function normalizeItemEntry(raw: any): GrantItemEntry?
	if typeof(raw) ~= "table" then
		return nil
	end
	local itemType = Types.normalizeItemType(raw.itemType)
	if not itemType then
		return nil
	end
	if typeof(raw.itemAmount) ~= "number" or raw.itemAmount ~= raw.itemAmount then
		return nil
	end
	local amount = math.floor(raw.itemAmount)
	if amount <= 0 then
		return nil
	end
	return {
		itemType = itemType,
		itemAmount = amount,
	}
end

local function normalizeCampaign(raw: any): GrantCampaignDefinition?
	if typeof(raw) ~= "table" then
		return nil
	end
	if typeof(raw.id) ~= "string" or raw.id == "" then
		return nil
	end
	if typeof(raw.items) ~= "table" then
		return nil
	end

	local items: { GrantItemEntry } = {}
	for _, row in raw.items do
		local entry = normalizeItemEntry(row)
		if entry then
			table.insert(items, entry)
		end
	end
	if #items == 0 then
		return nil
	end

	return {
		id = raw.id,
		enabled = raw.enabled == true,
		items = items,
	}
end

local function normalizeSource(raw: any): GrantDataSource?
	if typeof(raw) ~= "table" or typeof(raw.campaigns) ~= "table" then
		return nil
	end
	local campaigns: { GrantCampaignDefinition } = {}
	for _, row in raw.campaigns do
		local campaign = normalizeCampaign(row)
		if campaign then
			table.insert(campaigns, campaign)
		end
	end
	return { campaigns = campaigns }
end

function GrantHelper.loadGrantDataRaw(): any?
	if RunService:IsServer() then
		local folder = ServerStorage:FindFirstChild("DataTable")
		local moduleInst = folder and folder:FindFirstChild(GRANT_DATA_MODULE_NAME)
		if moduleInst and moduleInst:IsA("ModuleScript") then
			local ok, result = pcall(require, moduleInst)
			if ok then
				return result
			end
			warn("[GrantHelper] GrantData require 실패:", result)
		end
		return nil
	end
	return nil
end

function GrantHelper.getCampaigns(raw: any?): { GrantCampaignDefinition }
	local source = normalizeSource(raw)
	if not source then
		return {}
	end
	return source.campaigns
end

--- 캠페인 items 배열을 ItemType→수량 맵으로 합산 (동일 itemType은 합산)
function GrantHelper.resolveCampaignItems(campaign: GrantCampaignDefinition): { [Types.ItemType]: number }
	local out: { [Types.ItemType]: number } = {}
	for _, entry in campaign.items do
		out[entry.itemType] = (out[entry.itemType] or 0) + entry.itemAmount
	end
	return out
end

return GrantHelper
