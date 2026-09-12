--[[
	InventoryHelper (shared)

	아이템 마스터: ReplicatedStorage.DataTable.ItemData (클라) / ServerStorage.DataTable.ItemData (서버)
	RemoteFunction GetInventorySnapshot → { items: { { itemType, count }, ... } } (보유량 > 0만)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DataManager = require(Shared.Managers.DataManager)
local Types = require(Shared.Types)

local InventoryHelper = {}

export type InventoryItemEntry = {
	itemType: Types.ItemType,
	count: number,
}

export type InventorySnapshot = {
	items: { InventoryItemEntry },
}

export type ItemDefinition = {
	icon: string,
	title: string?,
	desc: string?,
}

local GET_SNAPSHOT_REMOTE_NAME = "GetInventorySnapshot"
local ITEM_DATA_MODULE_NAME = "ItemData"

local initialized = false
local itemDefsCache: { [Types.ItemType]: ItemDefinition }? = nil

local function loadItemDataRaw(): any?
	if RunService:IsServer() then
		local ok, result = pcall(function()
			return require(ServerStorage:WaitForChild("DataTable"):WaitForChild(ITEM_DATA_MODULE_NAME))
		end)
		if ok then
			return result
		end
		return nil
	end

	local ok, result = pcall(function()
		return require(ReplicatedStorage:WaitForChild("DataTable"):WaitForChild(ITEM_DATA_MODULE_NAME))
	end)
	if ok then
		return result
	end
	return nil
end

local function ensureItemDefs(): { [Types.ItemType]: ItemDefinition }
	if itemDefsCache then
		return itemDefsCache
	end

	local map: { [Types.ItemType]: ItemDefinition } = {}
	local raw = loadItemDataRaw()
	local itemsTable = if typeof(raw) == "table" then (raw :: any).items else nil
	if typeof(itemsTable) == "table" then
		for _, itemType in Types.ITEM_TYPES do
			local row = itemsTable[itemType]
			if typeof(row) == "table" and typeof(row.icon) == "string" and row.icon ~= "" then
				map[itemType] = {
					icon = row.icon,
					title = if typeof(row.title) == "string" then row.title else nil,
					desc = if typeof(row.desc) == "string" then row.desc else nil,
				}
			end
		end
	end

	itemDefsCache = map
	return map
end

function InventoryHelper.getItemDefinition(itemType: Types.ItemType): ItemDefinition?
	local normalized = Types.normalizeItemType(itemType)
	if not normalized then
		return nil
	end
	return ensureItemDefs()[normalized]
end

function InventoryHelper.getItemIconName(itemType: Types.ItemType): string?
	local def = InventoryHelper.getItemDefinition(itemType)
	return if def then def.icon else nil
end

function InventoryHelper.buildOwnedItems(player: Player): { InventoryItemEntry }
	local items: { InventoryItemEntry } = {}
	for _, itemType in Types.ITEM_TYPES do
		local count = DataManager.getItemCount(player, itemType)
		if count > 0 then
			table.insert(items, {
				itemType = itemType,
				count = count,
			})
		end
	end
	return items
end

function InventoryHelper.getSnapshot(player: Player): InventorySnapshot
	return {
		items = InventoryHelper.buildOwnedItems(player),
	}
end

local function getSnapshotRemoteOnClient(): RemoteFunction?
	local remote = ReplicatedStorage:FindFirstChild(GET_SNAPSHOT_REMOTE_NAME)
	if not remote then
		remote = ReplicatedStorage:WaitForChild(GET_SNAPSHOT_REMOTE_NAME, 10)
	end
	if not (remote and remote:IsA("RemoteFunction")) then
		warn("[InventoryHelper] GetInventorySnapshot RemoteFunction 없음")
		return nil
	end
	return remote :: RemoteFunction
end

-- 서버: 즉시 조회. 클라이언트: GetInventorySnapshot 원격 호출.
function InventoryHelper.fetchSnapshot(player: Player?): InventorySnapshot?
	if RunService:IsServer() then
		local target = player or Players.LocalPlayer
		if not target then
			return nil
		end
		if not DataManager.waitUntilLoaded(target) then
			return nil
		end
		return InventoryHelper.getSnapshot(target)
	end

	local remote = getSnapshotRemoteOnClient()
	if not remote then
		return nil
	end

	local ok, result = pcall(function()
		return remote:InvokeServer()
	end)
	if not ok then
		warn("[InventoryHelper] GetInventorySnapshot 실패:", result)
		return nil
	end
	if typeof(result) ~= "table" or typeof((result :: any).items) ~= "table" then
		warn("[InventoryHelper] GetInventorySnapshot 응답 형식 오류")
		return nil
	end
	return result :: InventorySnapshot
end

function InventoryHelper.getItemCountFromSnapshot(snapshot: InventorySnapshot?, itemType: Types.ItemType): number
	if not snapshot then
		return 0
	end
	local normalized = Types.normalizeItemType(itemType)
	if not normalized then
		return 0
	end
	for _, entry in snapshot.items do
		if entry.itemType == normalized then
			return entry.count
		end
	end
	return 0
end

local function bindRemotes()
	local snapshotExisting = ReplicatedStorage:FindFirstChild(GET_SNAPSHOT_REMOTE_NAME)
	local snapshotRemote = if snapshotExisting and snapshotExisting:IsA("RemoteFunction")
		then snapshotExisting
		else Instance.new("RemoteFunction")
	snapshotRemote.Name = GET_SNAPSHOT_REMOTE_NAME
	snapshotRemote.Parent = ReplicatedStorage
	snapshotRemote.OnServerInvoke = function(player: Player)
		if not DataManager.waitUntilLoaded(player) then
			return nil
		end
		return InventoryHelper.getSnapshot(player)
	end
end

function InventoryHelper.init()
	if initialized then
		return
	end
	initialized = true

	if RunService:IsServer() then
		ensureItemDefs()
		bindRemotes()
	end

	print("[InventoryHelper] 초기화 완료")
end

InventoryHelper.GET_SNAPSHOT_REMOTE_NAME = GET_SNAPSHOT_REMOTE_NAME

return InventoryHelper
