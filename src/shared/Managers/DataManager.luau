--[[
	서버 전용: 유저별 영구 데이터(DataStore) 로드/저장, 재화(Gem, Gold, BattlePassPoint) 관리,
	마스터 데이터 원본 로드 (RelicData, DailyRewardData, MissionData, AchievementData, StringData, ShopData, BattlePassData, GrantData).
	로비·스테이지 공용. 클라이언트 require 시 no-op.

	마스터 테이블: ServerStorage.DataTable (init 시 원본 로드)
	  - Shared.Helpers.* — getRelicDataRaw(), getDailyRewardDataRaw(), getMissionDataRaw(), getAchievementDataRaw(), getShopDataRaw(), getBattlePassDataRaw(), getGrantDataRaw() 참조
	    (마스터 테이블 전부 init 시 ReplicatedStorage.DataTable 로 복제 — GrantData는 서버 전용)
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Types = require(script.Parent.Parent.Types)
local TimeHelper = require(script.Parent.Parent.Helpers.TimeHelper)
local GrantHelper = require(script.Parent.Parent.Helpers.GrantHelper)

local DataManager = {}

export type CurrencyType = Types.CurrencyType
export type CurrencyBalance = Types.CurrencyBalance
export type SavedPlayerData = Types.SavedPlayerData
export type DailyRewardDatasetProgress = Types.DailyRewardDatasetProgress
export type DailyRewardProgress = Types.DailyRewardProgress
export type MissionProgress = Types.MissionProgress
export type AchievementProgress = Types.AchievementProgress
export type BattlePassProgress = Types.BattlePassProgress
export type RelicProgress = Types.RelicProgress
export type RelicProgressEntry = Types.RelicProgressEntry

local DATA_STORE_NAME = "TitanStrike_PlayerData_v1"
local DATA_VERSION = 3 -- v3: Relics 전체 lv.0 / xp 0 초기화
local DAILY_REWARD_DAYS = 7
local AUTO_SAVE_INTERVAL_SEC = 60
local LOAD_TIMEOUT_SEC = 15
local MAX_STORE_RETRIES = 5
local RETRY_BASE_DELAY_SEC = 1
local DATA_TABLE_FOLDER_NAME = "DataTable"
local RELIC_DATA_MODULE_NAME = "RelicData"
local COSTUME_DATA_MODULE_NAME = "CostumeData"
local DAILY_REWARD_DATA_MODULE_NAME = "DailyRewardData"
local MISSION_DATA_MODULE_NAME = "MissionData"
local ACHIEVEMENT_DATA_MODULE_NAME = "AchievementData"
local STRING_DATA_MODULE_NAME = "StringData"
local SHOP_DATA_MODULE_NAME = "ShopData"
local BATTLE_PASS_DATA_MODULE_NAME = "BattlePassData"
local GRANT_DATA_MODULE_NAME = "GrantData"
local ITEM_DATA_MODULE_NAME = "ItemData"
local OPTION_DATA_MODULE_NAME = "OptionData"
local STAGE_DATA_MODULE_NAME = "StageData"
local PET_DATA_MODULE_NAME = "PetData"

local DEFAULT_SAVED_DATA: SavedPlayerData = {
	DataVersion = DATA_VERSION,
	Currency = {
		Gem = 0,
		Gold = 0,
		BattlePassPoint = 0,
	},
	StageProgress = {},
	DailyReward = {},
	Inventory = {
		Item = {},
		Costume = {},
	},
	Relics = {},
	GrantedCampaigns = {},
	Mission = {
		missionDayStartTime = 0,
		selectedIndices = {},
		progress = {},
		claimed = {},
	},
	Achievement = {
		progress = {},
		claimed = {},
	},
	BattlePass = {
		level = 0,
		xp = 0,
		freeClaimedLevel = 0,
		premiumClaimedLevel = 0,
		maxLevelPremiumRewardClaimed = false,
	},
}

DataManager.CurrencyAttribute = {
	Gem = "Gem",
	Gold = "Gold",
	BattlePassPoint = "BattlePassPoint",
}

local ATTR_GEM = DataManager.CurrencyAttribute.Gem
local ATTR_GOLD = DataManager.CurrencyAttribute.Gold
local ATTR_BATTLE_PASS_POINT = DataManager.CurrencyAttribute.BattlePassPoint

if not RunService:IsServer() then
	local LocalPlayer = Players.LocalPlayer

	local function readLocalAttribute(attributeName: string): number
		local value = LocalPlayer:GetAttribute(attributeName)
		if typeof(value) == "number" and value == value then
			return math.max(0, math.floor(value))
		end
		return 0
	end

	local function serverOnly(apiName: string)
		warn(string.format(
			"[DataManager] %s called on CLIENT. This API is SERVER-only.",
			apiName
		))
	end

	function DataManager.getLocalGem(): number
		return readLocalAttribute(ATTR_GEM)
	end

	function DataManager.getLocalGold(): number
		return readLocalAttribute(ATTR_GOLD)
	end

	function DataManager.getLocalBattlePassPoint(): number
		return readLocalAttribute(ATTR_BATTLE_PASS_POINT)
	end

	function DataManager.init() end

	function DataManager.isLoaded(_player: Player): boolean
		serverOnly("isLoaded")
		return false
	end

	function DataManager.waitUntilLoaded(_player: Player, _timeoutSec: number?): boolean
		serverOnly("waitUntilLoaded")
		return false
	end

	function DataManager.getSavedData(_player: Player): SavedPlayerData?
		serverOnly("getSavedData")
		return nil
	end

	function DataManager.getCurrency(_player: Player, _currencyType: CurrencyType): number
		if _currencyType == "Gem" then
			return DataManager.getLocalGem()
		end
	
		if _currencyType == "Gold" then
			return DataManager.getLocalGold()
		end
	
		if _currencyType == "BattlePassPoint" then
			return DataManager.getLocalBattlePassPoint()
		end
	
		serverOnly("getCurrency(" .. tostring(_currencyType) .. ")")
		return 0
	end

	function DataManager.getGem(_player: Player): number
		return DataManager.getLocalGem()
	end

	function DataManager.getGold(_player: Player): number
		return DataManager.getLocalGold()
	end

	function DataManager.getBattlePassPoint(_player: Player): number
		return DataManager.getLocalBattlePassPoint()
	end

	function DataManager.addCurrency(_player: Player, _currencyType: CurrencyType, _amount: number): boolean
		serverOnly("addCurrency")
		return false
	end

	function DataManager.addItem(_player: Player, _itemType: Types.ItemType, _amount: number): boolean
		serverOnly("addItem")
		return false
	end

	function DataManager.getItemCount(_player: Player, _itemType: Types.ItemType): number
		serverOnly("getItemCount")
		return 0
	end

	function DataManager.spendCurrency(_player: Player, _currencyType: CurrencyType, _amount: number): boolean
		serverOnly("spendCurrency")
		return false
	end

	function DataManager.hasCostume(_player: Player, _costumeId: string): boolean
		serverOnly("hasCostume")
		return false
	end

	function DataManager.getOwnedCostumeIds(_player: Player): { string }
		serverOnly("getOwnedCostumeIds")
		return {}
	end

	function DataManager.addCostume(_player: Player, _costumeId: string): boolean
		serverOnly("addCostume")
		return false
	end

	function DataManager.getEquippedCostume(_player: Player): string?
		serverOnly("getEquippedCostume")
		return nil
	end

	function DataManager.setEquippedCostume(_player: Player, _costumeId: string?): boolean
		serverOnly("setEquippedCostume")
		return false
	end

	function DataManager.getDailyRewardEntry(_player: Player, _datasetIndex: number): DailyRewardDatasetProgress?
		serverOnly("getDailyRewardEntry")
		return nil
	end

	function DataManager.setDailyRewardEntry(
		_player: Player,
		_datasetIndex: number,
		_entry: DailyRewardDatasetProgress
	): boolean
		serverOnly("setDailyRewardEntry")
		return false
	end

	function DataManager.getMissionProgress(_player: Player): MissionProgress?
		serverOnly("getMissionProgress")
		return nil
	end

	function DataManager.setMissionProgress(_player: Player, _progress: MissionProgress): boolean
		serverOnly("setMissionProgress")
		return false
	end

	function DataManager.getAchievementProgress(_player: Player): AchievementProgress?
		serverOnly("getAchievementProgress")
		return nil
	end

	function DataManager.setAchievementProgress(_player: Player, _progress: AchievementProgress): boolean
		serverOnly("setAchievementProgress")
		return false
	end

	function DataManager.getBattlePassProgress(_player: Player): BattlePassProgress?
		serverOnly("getBattlePassProgress")
		return nil
	end

	function DataManager.setBattlePassProgress(_player: Player, _progress: BattlePassProgress): boolean
		serverOnly("setBattlePassProgress")
		return false
	end

	function DataManager.getRelicProgress(_player: Player): RelicProgress?
		serverOnly("getRelicProgress")
		return nil
	end

	function DataManager.getRelicProgressEntry(_player: Player, _relicId: number): RelicProgressEntry?
		serverOnly("getRelicProgressEntry")
		return nil
	end

	function DataManager.setRelicProgressEntry(
		_player: Player,
		_relicId: number,
		_entry: RelicProgressEntry
	): boolean
		serverOnly("setRelicProgressEntry")
		return false
	end

	function DataManager.savePlayerNow(_player: Player): boolean
		serverOnly("savePlayerNow")
		return false
	end

	function DataManager.registerGoldAddedListener(_listener: (Player, number) -> ())
		serverOnly("registerGoldAddedListener")
	end

	function DataManager.getRelicDataRaw(): any?
		serverOnly("getRelicDataRaw")
		return nil
	end

	function DataManager.getDailyRewardDataRaw(): any?
		serverOnly("getDailyRewardDataRaw")
		return nil
	end

	function DataManager.getMissionDataRaw(): any?
		serverOnly("getMissionDataRaw")
		return nil
	end

	function DataManager.getAchievementDataRaw(): any?
		serverOnly("getAchievementDataRaw")
		return nil
	end

	function DataManager.getStringDataRaw(): any?
		serverOnly("getStringDataRaw")
		return nil
	end

	function DataManager.getShopDataRaw(): any?
		serverOnly("getShopDataRaw")
		return nil
	end

	function DataManager.getBattlePassDataRaw(): any?
		serverOnly("getBattlePassDataRaw")
		return nil
	end

	function DataManager.getGrantDataRaw(): any?
		serverOnly("getGrantDataRaw")
		return nil
	end

	return DataManager
end

-- --- server ---

type PlayerSession = {
	data: SavedPlayerData,
	loaded: boolean,
	dirty: boolean,
	relicProgressResetPending: boolean?,
}

local playerStore = DataStoreService:GetDataStore(DATA_STORE_NAME)
local sessions: { [number]: PlayerSession } = {}
local initialized = false
local relicDataRaw: any? = nil
local dailyRewardDataRaw: any? = nil
local missionDataRaw: any? = nil
local achievementDataRaw: any? = nil
local stringDataRaw: any? = nil
local shopDataRaw: any? = nil
local battlePassDataRaw: any? = nil
local grantDataRaw: any? = nil

local function normalizeAmount(amount: any): number?
	if typeof(amount) ~= "number" or amount ~= amount then
		return nil
	end
	local n = math.floor(amount)
	if n <= 0 then
		return nil
	end
	return n
end

local function newEmptyClaimedDays(): { boolean }
	local claimedDays: { boolean } = {}
	for day = 1, DAILY_REWARD_DAYS do
		claimedDays[day] = false
	end
	return claimedDays
end

local function deepCopyDefault(): SavedPlayerData
	local currency = table.clone(DEFAULT_SAVED_DATA.Currency)
	return {
		DataVersion = DEFAULT_SAVED_DATA.DataVersion,
		Currency = currency,
		StageProgress = {},
		DailyReward = {},
		Inventory = {
			Item = {},
			Costume = {},
		},
		Relics = {},
		GrantedCampaigns = {},
		Mission = {
			missionDayStartTime = 0,
			selectedIndices = {},
			progress = {},
			claimed = {},
		},
		Achievement = {
			progress = {},
			claimed = {},
		},
		BattlePass = {
			level = 0,
			xp = 0,
			freeClaimedLevel = 0,
			premiumClaimedLevel = 0,
			maxLevelPremiumRewardClaimed = false,
		},
	}
end

local function normalizeBalance(raw: any): CurrencyBalance
	local gem = 0
	local gold = 0
	local battlePassPoint = 0
	if typeof(raw) == "table" then
		if typeof(raw.Gem) == "number" and raw.Gem == raw.Gem then
			gem = math.max(0, math.floor(raw.Gem))
		end
		if typeof(raw.Gold) == "number" and raw.Gold == raw.Gold then
			gold = math.max(0, math.floor(raw.Gold))
		end
		if typeof(raw.BattlePassPoint) == "number" and raw.BattlePassPoint == raw.BattlePassPoint then
			battlePassPoint = math.max(0, math.floor(raw.BattlePassPoint))
		end
	end
	return { Gem = gem, Gold = gold, BattlePassPoint = battlePassPoint }
end

local function normalizeClaimedDays(raw: any): { boolean }
	local claimedDays = newEmptyClaimedDays()
	if typeof(raw) ~= "table" then
		return claimedDays
	end
	for day = 1, DAILY_REWARD_DAYS do
		if raw[day] == true then
			claimedDays[day] = true
		end
	end
	return claimedDays
end

local function normalizeLastAttendanceTime(raw: any): number?
	if typeof(raw.lastAttendanceTime) == "number" and raw.lastAttendanceTime > 0 then
		return math.floor(raw.lastAttendanceTime)
	end
	if typeof(raw.lastAttendanceDate) == "string" and raw.lastAttendanceDate ~= "" then
		return TimeHelper.dateStringToUnix(raw.lastAttendanceDate)
	end
	return nil
end

local function normalizeMissionDayStartTime(raw: any): number
	if typeof(raw.missionDayStartTime) == "number" and raw.missionDayStartTime > 0 then
		return math.floor(raw.missionDayStartTime)
	end
	if typeof(raw.missionDayId) == "string" and raw.missionDayId ~= "" then
		local migrated = TimeHelper.dateStringToUnix(raw.missionDayId)
		if migrated then
			return migrated
		end
	end
	return 0
end

local function normalizeDailyRewardProgressEntry(raw: any): DailyRewardDatasetProgress?
	if typeof(raw) ~= "table" then
		return nil
	end
	local currentDay = if typeof(raw.currentDay) == "number" and raw.currentDay == raw.currentDay
		then math.clamp(math.floor(raw.currentDay), 1, DAILY_REWARD_DAYS)
		else nil
	local lastAttendanceTime = normalizeLastAttendanceTime(raw)
	if not currentDay or not lastAttendanceTime then
		return nil
	end
	return {
		currentDay = currentDay,
		claimedDays = normalizeClaimedDays(raw.claimedDays),
		lastAttendanceTime = lastAttendanceTime,
	}
end

local function normalizeItemInventory(raw: any): Types.ItemInventory
	local out: Types.ItemInventory = {}
	if typeof(raw) ~= "table" then
		return out
	end

	-- 레거시: Item = { { SpeedUp = 1 }, ... } 배열 형태 병합
	local looksLikeArrayOfBags = false
	for key, value in raw do
		if typeof(key) == "number" and typeof(value) == "table" then
			looksLikeArrayOfBags = true
			break
		end
	end
	if looksLikeArrayOfBags then
		for _, bag in raw do
			if typeof(bag) == "table" then
				for itemKey, count in bag do
					local itemType = Types.normalizeItemType(itemKey)
					if itemType and typeof(count) == "number" and count == count then
						out[itemType] = (out[itemType] or 0) + math.max(0, math.floor(count))
					end
				end
			end
		end
		return out
	end

	for itemKey, count in raw do
		local itemType = Types.normalizeItemType(itemKey)
		if itemType and typeof(count) == "number" and count == count then
			out[itemType] = math.max(0, math.floor(count))
		end
	end
	return out
end

local function normalizeInventory(raw: any): Types.InventoryData
	local out: Types.InventoryData = {
		Item = {},
		Costume = {},
	}
	if typeof(raw) ~= "table" then
		return out
	end
	out.Item = normalizeItemInventory(raw.Item)
	if typeof(raw.Costume) == "table" then
		for _, costume in raw.Costume do
			if typeof(costume) == "string" then
				table.insert(out.Costume, costume)
			end
		end
	end

	if typeof(raw.EquippedCostume) == "string" and raw.EquippedCostume ~= "" then
		local stillOwned = false
		for _, costume in out.Costume do
			if costume == raw.EquippedCostume then
				stillOwned = true
				break
			end
		end
		if stillOwned then
			out.EquippedCostume = raw.EquippedCostume
		end
	end

	return out
end

local RELIC_MAX_LEVEL = 4

local function normalizeRelicProgressEntry(raw: any): RelicProgressEntry?
	if typeof(raw) ~= "table" then
		return nil
	end
	local level = if typeof(raw.level) == "number" and raw.level == raw.level then math.floor(raw.level) else nil
	local xp = if typeof(raw.xp) == "number" and raw.xp == raw.xp then math.floor(raw.xp) else nil
	if level == nil or xp == nil then
		return nil
	end
	level = math.clamp(level, 0, RELIC_MAX_LEVEL)
	xp = math.max(0, xp)
	if level >= RELIC_MAX_LEVEL then
		xp = 0
	end
	return {
		level = level,
		xp = xp,
	}
end

local function normalizeRelicProgress(raw: any): RelicProgress
	local out: RelicProgress = {}
	if typeof(raw) ~= "table" then
		return out
	end
	for key, entryRaw in raw do
		local relicId = if typeof(key) == "number" then key else tonumber(key)
		if typeof(relicId) ~= "number" or relicId ~= relicId then
			continue
		end
		relicId = math.floor(relicId)
		if relicId < 1 then
			continue
		end
		local entry = normalizeRelicProgressEntry(entryRaw)
		if entry then
			out[relicId] = entry
		end
	end
	return out
end

local function cloneRelicProgress(progress: RelicProgress): RelicProgress
	local out: RelicProgress = {}
	for relicId, entry in progress do
		out[relicId] = {
			level = entry.level,
			xp = entry.xp,
		}
	end
	return out
end

local function isRelicProgressAhead(a: RelicProgressEntry, b: RelicProgressEntry): boolean
	if a.level ~= b.level then
		return a.level > b.level
	end
	return a.xp > b.xp
end

local function mergeRelicProgress(left: RelicProgress, right: RelicProgress): RelicProgress
	local out = cloneRelicProgress(left)
	for relicId, rightEntry in right do
		local leftEntry = out[relicId]
		if not leftEntry or isRelicProgressAhead(rightEntry, leftEntry) then
			out[relicId] = {
				level = rightEntry.level,
				xp = rightEntry.xp,
			}
		end
	end
	return out
end

local function normalizeGrantedCampaigns(raw: any): Types.GrantedCampaigns
	local out: Types.GrantedCampaigns = {}
	if typeof(raw) ~= "table" then
		return out
	end
	for key, value in raw do
		if typeof(key) == "string" and key ~= "" and (value == true or value == 1) then
			out[key] = true
		end
	end
	return out
end

--- 아이템 보유 수량은 consumeItem으로 감소할 수 있으므로 math.max로 병합하면 안 됨
--- (감소분이 저장 시 이전 값으로 다시 튕겨 올라감) — 현재 세션(right) 값을 그대로 채택.
local function mergeItemInventory(
	left: Types.ItemInventory,
	right: Types.ItemInventory
): Types.ItemInventory
	local out: Types.ItemInventory = table.clone(left)
	for itemType, count in right do
		out[itemType] = count
	end
	return out
end

local function mergeGrantedCampaigns(
	left: Types.GrantedCampaigns,
	right: Types.GrantedCampaigns
): Types.GrantedCampaigns
	local out: Types.GrantedCampaigns = table.clone(left)
	for id, claimed in right do
		if claimed then
			out[id] = true
		end
	end
	return out
end

local function mergeInventoryRecords(left: Types.InventoryData, right: Types.InventoryData): Types.InventoryData
	local costumes: { string } = table.clone(left.Costume)
	local costumeSeen: { [string]: boolean } = {}
	for _, costume in costumes do
		costumeSeen[costume] = true
	end
	for _, costume in right.Costume do
		if not costumeSeen[costume] then
			costumeSeen[costume] = true
			table.insert(costumes, costume)
		end
	end
	return {
		Item = mergeItemInventory(left.Item, right.Item),
		Costume = costumes,
		-- 장착 상태는 누적 목록이 아니라 단일 현재 선택이므로 Item처럼 현재 세션(right) 값을 그대로 채택.
		-- right가 nil이어도 "정보 없음"이 아니라 "장착 해제됨"이라는 뜻이므로 left로 되돌리면 안 됨.
		EquippedCostume = right.EquippedCostume,
	}
end

local function normalizeMissionProgress(raw: any): MissionProgress
	local out: MissionProgress = {
		missionDayStartTime = normalizeMissionDayStartTime(raw),
		selectedIndices = {},
		progress = {},
		claimed = {},
	}
	if typeof(raw) ~= "table" then
		return out
	end
	if typeof(raw.selectedIndices) == "table" then
		local seen: { [number]: boolean } = {}
		for _, value in raw.selectedIndices do
			local index = tonumber(value)
			if index and not seen[index] then
				seen[index] = true
				table.insert(out.selectedIndices, index)
			end
		end
		table.sort(out.selectedIndices)
	end
	if typeof(raw.progress) == "table" then
		for key, value in raw.progress do
			local index = tonumber(key)
			if index and typeof(value) == "number" and value == value then
				out.progress[index] = math.max(0, math.floor(value))
			end
		end
	end
	if typeof(raw.claimed) == "table" then
		for key, value in raw.claimed do
			local index = tonumber(key)
			if index and (value == true or value == 1) then
				out.claimed[index] = true
			end
		end
	end
	if typeof(raw.claimedIndices) == "table" then
		for _, idx in raw.claimedIndices do
			local index = tonumber(idx)
			if index then
				out.claimed[index] = true
			end
		end
	end
	return out
end

local function normalizeBattlePassProgress(raw: any): BattlePassProgress
	local out: BattlePassProgress = {
		level = 0,
		xp = 0,
		freeClaimedLevel = 0,
		premiumClaimedLevel = 0,
		maxLevelPremiumRewardClaimed = false,
	}
	if typeof(raw) ~= "table" then
		return out
	end
	if typeof(raw.level) == "number" and raw.level == raw.level then
		out.level = math.max(0, math.floor(raw.level))
	end
	if typeof(raw.xp) == "number" and raw.xp == raw.xp then
		out.xp = math.max(0, math.floor(raw.xp))
	end
	if typeof(raw.freeClaimedLevel) == "number" and raw.freeClaimedLevel == raw.freeClaimedLevel then
		out.freeClaimedLevel = math.max(0, math.floor(raw.freeClaimedLevel))
	end
	if typeof(raw.premiumClaimedLevel) == "number" and raw.premiumClaimedLevel == raw.premiumClaimedLevel then
		out.premiumClaimedLevel = math.max(0, math.floor(raw.premiumClaimedLevel))
	end
	if raw.maxLevelPremiumRewardClaimed == true then
		out.maxLevelPremiumRewardClaimed = true
	end
	return out
end

local function getBattlePassMaxLevelFromRaw(): number
	local raw = battlePassDataRaw
	if typeof(raw) == "table" and typeof(raw.maxLevel) == "number" and raw.maxLevel == raw.maxLevel then
		return math.max(1, math.floor(raw.maxLevel))
	end
	return 30
end

local function getBattlePassXpRequiredForLevel(level: number): number
	local raw = battlePassDataRaw
	if typeof(raw) == "table" and typeof(raw.levels) == "table" then
		local row = raw.levels[level]
		if typeof(row) == "table" and typeof(row.xpRequired) == "number" and row.xpRequired == row.xpRequired then
			return math.max(1, math.floor(row.xpRequired))
		end
	end
	return math.max(1, 100 + (level - 1) * 10)
end

local function applyBattlePassXpByPoint(progress: BattlePassProgress, addedPoint: number): BattlePassProgress
	local out = normalizeBattlePassProgress(progress)
	local remaining = math.max(0, math.floor(addedPoint))
	local maxLevel = getBattlePassMaxLevelFromRaw()

	while remaining > 0 and out.level < maxLevel do
		local nextLevel = out.level + 1
		local xpRequired = getBattlePassXpRequiredForLevel(nextLevel)
		local need = math.max(1, xpRequired - out.xp)

		if remaining >= need then
			remaining -= need
			out.level = nextLevel
			out.xp = 0
		else
			out.xp += remaining
			remaining = 0
		end
	end

	if out.level >= maxLevel then
		out.level = maxLevel
		out.xp = getBattlePassXpRequiredForLevel(maxLevel)
	end

	return out
end

local function normalizeAchievementProgress(raw: any): AchievementProgress
	local out: AchievementProgress = {
		progress = {},
		claimed = {},
	}
	if typeof(raw) ~= "table" then
		return out
	end
	if typeof(raw.progress) == "table" then
		for key, value in raw.progress do
			local index = tonumber(key)
			if index and typeof(value) == "number" and value == value then
				out.progress[index] = math.max(0, math.floor(value))
			end
		end
	end
	if typeof(raw.claimed) == "table" then
		for key, value in raw.claimed do
			local index = tonumber(key)
			if index and (value == true or value == 1) then
				out.claimed[index] = true
			end
		end
	end
	if typeof(raw.claimedIndices) == "table" then
		for _, idx in raw.claimedIndices do
			local index = tonumber(idx)
			if index then
				out.claimed[index] = true
			end
		end
	end
	return out
end

local function normalizeDailyRewardProgress(raw: any): DailyRewardProgress
	local out: DailyRewardProgress = {}
	if typeof(raw) ~= "table" then
		return out
	end
	for key, entryRaw in raw do
		local datasetIndex = if typeof(key) == "number" then math.floor(key) else tonumber(key)
		if datasetIndex == nil then
			continue
		end
		local entry = normalizeDailyRewardProgressEntry(entryRaw)
		if entry then
			out[datasetIndex] = entry
		end
	end
	return out
end

local function normalizeStageProgress(raw: any): { [number]: boolean }
	local out: { [number]: boolean } = {}
	if typeof(raw) ~= "table" then
		return out
	end
	for key, value in raw do
		local stageNumber = tonumber(key)
		if stageNumber and value == true then
			out[stageNumber] = true
		end
	end
	return out
end

local function normalizeSavedData(raw: any): SavedPlayerData
	if typeof(raw) ~= "table" then
		return deepCopyDefault()
	end
	return {
		DataVersion = DATA_VERSION,
		Currency = normalizeBalance(raw.Currency),
		StageProgress = normalizeStageProgress(raw.StageProgress),
		DailyReward = normalizeDailyRewardProgress(raw.DailyReward),
		Inventory = normalizeInventory(raw.Inventory),
		Relics = normalizeRelicProgress(raw.Relics),
		GrantedCampaigns = normalizeGrantedCampaigns(raw.GrantedCampaigns),
		Mission = normalizeMissionProgress(raw.Mission),
		Achievement = normalizeAchievementProgress(raw.Achievement),
		BattlePass = normalizeBattlePassProgress(raw.BattlePass),
	}
end

local function mergeIndexProgressMaps(
	current: { [number]: number },
	incoming: { [number]: number }
): { [number]: number }
	local out: { [number]: number } = table.clone(current)
	for index, value in incoming do
		if typeof(value) == "number" and value == value then
			local normalized = math.max(0, math.floor(value))
			local prev = out[index] or 0
			out[index] = math.max(prev, normalized)
		end
	end
	return out
end

local function mergeIndexClaimedMaps(
	current: { [number]: boolean },
	incoming: { [number]: boolean }
): { [number]: boolean }
	local out: { [number]: boolean } = {}
	for index, value in current do
		if value == true or value == 1 then
			out[index] = true
		end
	end
	for index, value in incoming do
		if value == true or value == 1 then
			out[index] = true
		end
	end
	return out
end

local function mergeAchievementProgressRecords(
	existing: AchievementProgress,
	incoming: AchievementProgress
): AchievementProgress
	local left = normalizeAchievementProgress(existing)
	local right = normalizeAchievementProgress(incoming)
	return {
		progress = mergeIndexProgressMaps(left.progress, right.progress),
		claimed = mergeIndexClaimedMaps(left.claimed, right.claimed),
	}
end

local function mergeMissionProgressRecords(existing: MissionProgress, incoming: MissionProgress): MissionProgress
	local left = normalizeMissionProgress(existing)
	local right = normalizeMissionProgress(incoming)
	if left.missionDayStartTime ~= right.missionDayStartTime then
		if right.missionDayStartTime > left.missionDayStartTime then
			return right
		end
		return left
	end
	return {
		missionDayStartTime = left.missionDayStartTime,
		selectedIndices = if #left.selectedIndices > 0 then left.selectedIndices else right.selectedIndices,
		progress = mergeIndexProgressMaps(left.progress, right.progress),
		claimed = mergeIndexClaimedMaps(left.claimed, right.claimed),
	}
end

local function mergeStageProgressRecords(
	existing: { [number]: boolean },
	incoming: { [number]: boolean }
): { [number]: boolean }
	local out: { [number]: boolean } = table.clone(existing)
	for stageNumber, cleared in incoming do
		if cleared == true or cleared == 1 then
			out[stageNumber] = true
		end
	end
	return out
end

local function mergeBattlePassProgressRecords(
	existing: BattlePassProgress,
	incoming: BattlePassProgress
): BattlePassProgress
	local left = normalizeBattlePassProgress(existing)
	local right = normalizeBattlePassProgress(incoming)

	local newer = right
	if left.level > right.level or (left.level == right.level and left.xp > right.xp) then
		newer = left
	end

	return {
		level = newer.level,
		xp = newer.xp,
		freeClaimedLevel = math.max(left.freeClaimedLevel, right.freeClaimedLevel),
		premiumClaimedLevel = math.max(left.premiumClaimedLevel, right.premiumClaimedLevel),
		maxLevelPremiumRewardClaimed = left.maxLevelPremiumRewardClaimed or right.maxLevelPremiumRewardClaimed,
	}
end

local function mergeSavedPlayerData(existing: SavedPlayerData, incoming: SavedPlayerData): SavedPlayerData
	local left = normalizeSavedData(existing)
	local right = normalizeSavedData(incoming)
	return {
		DataVersion = DATA_VERSION,
		-- Currency도 Item과 마찬가지로 spendCurrency로 감소할 수 있어 math.max 병합 불가 — right 그대로 채택
		Currency = right.Currency,
		StageProgress = mergeStageProgressRecords(left.StageProgress, right.StageProgress),
		DailyReward = right.DailyReward,
		Inventory = mergeInventoryRecords(left.Inventory, right.Inventory),
		Relics = mergeRelicProgress(left.Relics, right.Relics),
		GrantedCampaigns = mergeGrantedCampaigns(left.GrantedCampaigns, right.GrantedCampaigns),
		Mission = mergeMissionProgressRecords(left.Mission, right.Mission),
		Achievement = mergeAchievementProgressRecords(left.Achievement, right.Achievement),
		BattlePass = mergeBattlePassProgressRecords(left.BattlePass, right.BattlePass),
	}
end

local function collectClaimedIndices(claimed: { [number]: boolean }): { number }
	local indices: { number } = {}
	for index, value in claimed do
		if value == true or value == 1 then
			table.insert(indices, index)
		end
	end
	table.sort(indices)
	return indices
end

local function encodeMissionForPersistence(mission: MissionProgress): any
	local normalized = normalizeMissionProgress(mission)
	return {
		missionDayStartTime = normalized.missionDayStartTime,
		selectedIndices = normalized.selectedIndices,
		progress = normalized.progress,
		claimedIndices = collectClaimedIndices(normalized.claimed),
	}
end

local function encodeAchievementForPersistence(achievement: AchievementProgress): any
	local normalized = normalizeAchievementProgress(achievement)
	return {
		progress = normalized.progress,
		claimedIndices = collectClaimedIndices(normalized.claimed),
	}
end

local function prepareSavedDataForStore(data: SavedPlayerData): SavedPlayerData
	local normalized = normalizeSavedData(data)
	return {
		DataVersion = normalized.DataVersion,
		Currency = normalized.Currency,
		StageProgress = normalized.StageProgress,
		DailyReward = normalized.DailyReward,
		Inventory = normalized.Inventory,
		Relics = normalized.Relics,
		GrantedCampaigns = normalized.GrantedCampaigns,
		Mission = encodeMissionForPersistence(normalized.Mission),
		Achievement = encodeAchievementForPersistence(normalized.Achievement),
		BattlePass = normalized.BattlePass,
	}
end

local function withStoreRetry<T>(label: string, userId: number, callback: () -> T): (boolean, T?)
	for attempt = 1, MAX_STORE_RETRIES do
		local ok, result = pcall(callback)
		if ok then
			return true, result
		end
		warn(string.format("[DataManager] %s 실패 userId=%d attempt=%d: %s", label, userId, attempt, tostring(result)))
		if attempt < MAX_STORE_RETRIES then
			task.wait(RETRY_BASE_DELAY_SEC * attempt)
		end
	end
	return false, nil
end

local function syncCurrencyAttributes(player: Player, currency: CurrencyBalance)
	player:SetAttribute(ATTR_GEM, currency.Gem)
	player:SetAttribute(ATTR_GOLD, currency.Gold)
	player:SetAttribute(ATTR_BATTLE_PASS_POINT, currency.BattlePassPoint)
end

type GoldAddedListener = (Player, number) -> ()

local goldAddedListeners: { GoldAddedListener } = {}

local function notifyGoldAdded(player: Player, amount: number)
	for _, listener in goldAddedListeners do
		task.defer(listener, player, amount)
	end
end

function DataManager.registerGoldAddedListener(listener: GoldAddedListener)
	table.insert(goldAddedListeners, listener)
end

local function getSession(userId: number): PlayerSession?
	return sessions[userId]
end

local function markDirty(session: PlayerSession)
	session.dirty = true
end

local function loadPlayerData(userId: number): (SavedPlayerData, boolean)
	local key = tostring(userId)
	local ok, stored = withStoreRetry("Load", userId, function()
		return playerStore:GetAsync(key)
	end)
	if ok and stored ~= nil then
		local storedVersion = 0
		if typeof(stored) == "table" and typeof(stored.DataVersion) == "number" then
			storedVersion = stored.DataVersion
		end
		local data = normalizeSavedData(stored)
		local relicResetPending = storedVersion < DATA_VERSION
		if relicResetPending then
			data.Relics = {}
		end
		return data, relicResetPending
	end
	return deepCopyDefault(), false
end

local function savePlayerData(
	userId: number,
	data: SavedPlayerData,
	forceRelicReset: boolean?
): (boolean, SavedPlayerData?)
	local key = tostring(userId)
	local inMemory = normalizeSavedData(data)
	local snapshotForStore = prepareSavedDataForStore(inMemory)
	local mergedResult: SavedPlayerData? = nil
	local ok = withStoreRetry("Save", userId, function()
		mergedResult = playerStore:UpdateAsync(key, function(old)
			if old == nil then
				return snapshotForStore
			end
			local merged = mergeSavedPlayerData(normalizeSavedData(old), inMemory)
			if forceRelicReset then
				merged.Relics = {}
			end
			return prepareSavedDataForStore(merged)
		end)
		return true
	end)
	if ok ~= true then
		return false, nil
	end
	if mergedResult ~= nil then
		return true, normalizeSavedData(mergedResult)
	end
	return true, inMemory
end

local function saveSession(userId: number): boolean
	local session = sessions[userId]
	if not session or not session.loaded or not session.dirty then
		return true
	end
	local forceRelicReset = session.relicProgressResetPending == true
	local ok, merged = savePlayerData(userId, session.data, forceRelicReset)
	if ok then
		if merged then
			session.data = merged
		end
		if forceRelicReset then
			session.relicProgressResetPending = false
		end
		session.dirty = false
	end
	return ok
end

local function applyPendingGrantCampaigns(player: Player, session: PlayerSession): boolean
	local campaigns = GrantHelper.getCampaigns(grantDataRaw)
	if #campaigns == 0 then
		return false
	end

	local grantedAny = false
	for _, campaign in campaigns do
		if not campaign.enabled then
			continue
		end
		if session.data.GrantedCampaigns[campaign.id] == true then
			continue
		end

		local items = GrantHelper.resolveCampaignItems(campaign)
		local grantedThisCampaign = false
		for itemType, amount in items do
			local current = session.data.Inventory.Item[itemType] or 0
			session.data.Inventory.Item[itemType] = current + amount
			grantedThisCampaign = true
		end

		if grantedThisCampaign then
			session.data.GrantedCampaigns[campaign.id] = true
			grantedAny = true
			print(string.format(
				"[DataManager] Grant 적용: %s campaign=%s",
				player.Name,
				campaign.id
			))
		end
	end

	return grantedAny
end

local function onPlayerAdded(player: Player)
	local userId = player.UserId
	if sessions[userId] then
		return
	end

	local session: PlayerSession = {
		data = deepCopyDefault(),
		loaded = false,
		dirty = false,
	}
	sessions[userId] = session

	task.spawn(function()
		local data, relicResetPending = loadPlayerData(userId)
		if not player.Parent then
			sessions[userId] = nil
			return
		end
		session.data = data
		session.loaded = true
		if relicResetPending then
			session.relicProgressResetPending = true
			print(string.format("[DataManager] Relics 초기화 적용: %s (DataVersion → %d)", player.Name, DATA_VERSION))
		end
		if applyPendingGrantCampaigns(player, session) or relicResetPending then
			markDirty(session)
			saveSession(userId)
		end
		syncCurrencyAttributes(player, session.data.Currency)
		print(
			string.format(
				"[DataManager] 로드 완료: %s Gem=%d Gold=%d BattlePassPoint=%d",
				player.Name,
				session.data.Currency.Gem,
				session.data.Currency.Gold,
				session.data.Currency.BattlePassPoint
			)
		)
	end)
end

function DataManager.savePlayerNow(player: Player): boolean
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		return false
	end
	return saveSession(player.UserId)
end

local function onPlayerRemoving(player: Player)
	local userId = player.UserId
	local session = sessions[userId]
	if not session then
		return
	end
	if session.loaded then
		saveSession(userId)
	end
	sessions[userId] = nil
	print("[DataManager] 세션 종료:", player.Name)
end

local function saveAllDirty()
	for userId in sessions do
		saveSession(userId)
	end
end

local function startAutoSaveLoop()
	task.spawn(function()
		while true do
			task.wait(AUTO_SAVE_INTERVAL_SEC)
			saveAllDirty()
		end
	end)
end

local function loadRelicDataFromServerStorage(): any?
	local folder = ServerStorage:FindFirstChild(DATA_TABLE_FOLDER_NAME)
	if not folder then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s 없음 (src/datatable/RelicData.luau)",
				DATA_TABLE_FOLDER_NAME
			)
		)
		return nil
	end
	local moduleScript = folder:FindFirstChild(RELIC_DATA_MODULE_NAME)
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s.%s 없음",
				DATA_TABLE_FOLDER_NAME,
				RELIC_DATA_MODULE_NAME
			)
		)
		return nil
	end

	local ok, raw = pcall(require, moduleScript)
	if not ok then
		warn("[DataManager] RelicData require 실패:", raw)
		return nil
	end
	return raw
end

local function loadDailyRewardDataFromServerStorage(): any?
	local folder = ServerStorage:FindFirstChild(DATA_TABLE_FOLDER_NAME)
	if not folder then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s 없음 (src/datatable/DailyRewardData.luau)",
				DATA_TABLE_FOLDER_NAME
			)
		)
		return nil
	end
	local moduleScript = folder:FindFirstChild(DAILY_REWARD_DATA_MODULE_NAME)
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s.%s 없음",
				DATA_TABLE_FOLDER_NAME,
				DAILY_REWARD_DATA_MODULE_NAME
			)
		)
		return nil
	end

	local ok, raw = pcall(require, moduleScript)
	if not ok then
		warn("[DataManager] DailyRewardData require 실패:", raw)
		return nil
	end
	return raw
end

local function loadMissionDataFromServerStorage(): any?
	local folder = ServerStorage:FindFirstChild(DATA_TABLE_FOLDER_NAME)
	if not folder then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s 없음 (src/datatable/MissionData.luau)",
				DATA_TABLE_FOLDER_NAME
			)
		)
		return nil
	end
	local moduleScript = folder:FindFirstChild(MISSION_DATA_MODULE_NAME)
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s.%s 없음",
				DATA_TABLE_FOLDER_NAME,
				MISSION_DATA_MODULE_NAME
			)
		)
		return nil
	end

	local ok, raw = pcall(require, moduleScript)
	if not ok then
		warn("[DataManager] MissionData require 실패:", raw)
		return nil
	end
	return raw
end

local function loadAchievementDataFromServerStorage(): any?
	local folder = ServerStorage:FindFirstChild(DATA_TABLE_FOLDER_NAME)
	if not folder then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s 없음 (src/datatable/AchievementData.luau)",
				DATA_TABLE_FOLDER_NAME
			)
		)
		return nil
	end
	local moduleScript = folder:FindFirstChild(ACHIEVEMENT_DATA_MODULE_NAME)
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s.%s 없음",
				DATA_TABLE_FOLDER_NAME,
				ACHIEVEMENT_DATA_MODULE_NAME
			)
		)
		return nil
	end

	local ok, raw = pcall(require, moduleScript)
	if not ok then
		warn("[DataManager] AchievementData require 실패:", raw)
		return nil
	end
	return raw
end

local function loadShopDataFromServerStorage(): any?
	local folder = ServerStorage:FindFirstChild(DATA_TABLE_FOLDER_NAME)
	if not folder then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s 없음 (src/datatable/ShopData.luau)",
				DATA_TABLE_FOLDER_NAME
			)
		)
		return nil
	end
	local moduleScript = folder:FindFirstChild(SHOP_DATA_MODULE_NAME)
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s.%s 없음",
				DATA_TABLE_FOLDER_NAME,
				SHOP_DATA_MODULE_NAME
			)
		)
		return nil
	end

	local ok, raw = pcall(require, moduleScript)
	if not ok then
		warn("[DataManager] ShopData require 실패:", raw)
		return nil
	end
	return raw
end

local function loadStringDataFromServerStorage(): any?
	local folder = ServerStorage:FindFirstChild(DATA_TABLE_FOLDER_NAME)
	if not folder then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s 없음 (src/datatable/StringData.luau)",
				DATA_TABLE_FOLDER_NAME
			)
		)
		return nil
	end
	local moduleScript = folder:FindFirstChild(STRING_DATA_MODULE_NAME)
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s.%s 없음",
				DATA_TABLE_FOLDER_NAME,
				STRING_DATA_MODULE_NAME
			)
		)
		return nil
	end

	local ok, raw = pcall(require, moduleScript)
	if not ok then
		warn("[DataManager] StringData require 실패:", raw)
		return nil
	end
	return raw
end

local function loadBattlePassDataFromServerStorage(): any?
	local folder = ServerStorage:FindFirstChild(DATA_TABLE_FOLDER_NAME)
	if not folder then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s 없음 (src/datatable/BattlePassData.luau)",
				DATA_TABLE_FOLDER_NAME
			)
		)
		return nil
	end
	local moduleScript = folder:FindFirstChild(BATTLE_PASS_DATA_MODULE_NAME)
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s.%s 없음",
				DATA_TABLE_FOLDER_NAME,
				BATTLE_PASS_DATA_MODULE_NAME
			)
		)
		return nil
	end

	local ok, raw = pcall(require, moduleScript)
	if not ok then
		warn("[DataManager] BattlePassData require 실패:", raw)
		return nil
	end
	return raw
end

local function loadGrantDataFromServerStorage(): any?
	local folder = ServerStorage:FindFirstChild(DATA_TABLE_FOLDER_NAME)
	if not folder then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s 없음 (src/datatable/GrantData.luau)",
				DATA_TABLE_FOLDER_NAME
			)
		)
		return nil
	end
	local moduleScript = folder:FindFirstChild(GRANT_DATA_MODULE_NAME)
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		warn(
			string.format(
				"[DataManager] ServerStorage.%s.%s 없음",
				DATA_TABLE_FOLDER_NAME,
				GRANT_DATA_MODULE_NAME
			)
		)
		return nil
	end

	local ok, raw = pcall(require, moduleScript)
	if not ok then
		warn("[DataManager] GrantData require 실패:", raw)
		return nil
	end
	return raw
end

local function replicateDataTableModuleForClients(moduleName: string, moduleScript: ModuleScript)
	local folder = ReplicatedStorage:FindFirstChild(DATA_TABLE_FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = DATA_TABLE_FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end

	local existing = folder:FindFirstChild(moduleName)
	if existing then
		existing:Destroy()
	end

	moduleScript:Clone().Parent = folder
end

function DataManager.init()
	if initialized then
		return
	end
	initialized = true

	relicDataRaw = loadRelicDataFromServerStorage()
	if relicDataRaw ~= nil then
		print("[DataManager] RelicData 원본 로드 완료")
	else
		warn("[DataManager] RelicData 원본 없음 — RelicHelper fallback 사용")
	end

	dailyRewardDataRaw = loadDailyRewardDataFromServerStorage()
	if dailyRewardDataRaw ~= nil then
		print("[DataManager] DailyRewardData 원본 로드 완료")
	else
		warn("[DataManager] DailyRewardData 원본 없음 — DailyRewardHelper fallback 사용")
	end

	missionDataRaw = loadMissionDataFromServerStorage()
	if missionDataRaw ~= nil then
		print("[DataManager] MissionData 원본 로드 완료")
	else
		warn("[DataManager] MissionData 원본 없음 — MissionHelper fallback 사용")
	end

	achievementDataRaw = loadAchievementDataFromServerStorage()
	if achievementDataRaw ~= nil then
		print("[DataManager] AchievementData 원본 로드 완료")
	else
		warn("[DataManager] AchievementData 원본 없음 — AchievementHelper fallback 사용")
	end

	shopDataRaw = loadShopDataFromServerStorage()
	if shopDataRaw ~= nil then
		print("[DataManager] ShopData 원본 로드 완료")
	else
		warn("[DataManager] ShopData 원본 없음 — ShopHelper fallback 사용")
	end

	battlePassDataRaw = loadBattlePassDataFromServerStorage()
	if battlePassDataRaw ~= nil then
		print("[DataManager] BattlePassData 원본 로드 완료")
	else
		warn("[DataManager] BattlePassData 원본 없음 — BattlePassHelper fallback 사용")
	end

	grantDataRaw = loadGrantDataFromServerStorage()
	if grantDataRaw ~= nil then
		print("[DataManager] GrantData 원본 로드 완료")
	else
		warn("[DataManager] GrantData 원본 없음 — 캠페인 지급 스킵")
	end

	local dataTableFolder = ServerStorage:FindFirstChild(DATA_TABLE_FOLDER_NAME)
	if dataTableFolder then
		local stringDataModule = dataTableFolder:FindFirstChild(STRING_DATA_MODULE_NAME)
		if stringDataModule and stringDataModule:IsA("ModuleScript") then
			replicateDataTableModuleForClients(STRING_DATA_MODULE_NAME, stringDataModule)
		end
		local missionDataModule = dataTableFolder:FindFirstChild(MISSION_DATA_MODULE_NAME)
		if missionDataModule and missionDataModule:IsA("ModuleScript") then
			replicateDataTableModuleForClients(MISSION_DATA_MODULE_NAME, missionDataModule)
		end
		local achievementDataModule = dataTableFolder:FindFirstChild(ACHIEVEMENT_DATA_MODULE_NAME)
		if achievementDataModule and achievementDataModule:IsA("ModuleScript") then
			replicateDataTableModuleForClients(ACHIEVEMENT_DATA_MODULE_NAME, achievementDataModule)
		end
		local shopDataModule = dataTableFolder:FindFirstChild(SHOP_DATA_MODULE_NAME)
		if shopDataModule and shopDataModule:IsA("ModuleScript") then
			replicateDataTableModuleForClients(SHOP_DATA_MODULE_NAME, shopDataModule)
		end
		local relicDataModule = dataTableFolder:FindFirstChild(RELIC_DATA_MODULE_NAME)
		if relicDataModule and relicDataModule:IsA("ModuleScript") then
			replicateDataTableModuleForClients(RELIC_DATA_MODULE_NAME, relicDataModule)
		end
		local costumeDataModule = dataTableFolder:FindFirstChild(COSTUME_DATA_MODULE_NAME)
		if costumeDataModule and costumeDataModule:IsA("ModuleScript") then
			replicateDataTableModuleForClients(COSTUME_DATA_MODULE_NAME, costumeDataModule)
		end
		local dailyRewardDataModule = dataTableFolder:FindFirstChild(DAILY_REWARD_DATA_MODULE_NAME)
		if dailyRewardDataModule and dailyRewardDataModule:IsA("ModuleScript") then
			replicateDataTableModuleForClients(DAILY_REWARD_DATA_MODULE_NAME, dailyRewardDataModule)
		end
		local battlePassDataModule = dataTableFolder:FindFirstChild(BATTLE_PASS_DATA_MODULE_NAME)
		if battlePassDataModule and battlePassDataModule:IsA("ModuleScript") then
			replicateDataTableModuleForClients(BATTLE_PASS_DATA_MODULE_NAME, battlePassDataModule)
		end
		local itemDataModule = dataTableFolder:FindFirstChild(ITEM_DATA_MODULE_NAME)
		if itemDataModule and itemDataModule:IsA("ModuleScript") then
			replicateDataTableModuleForClients(ITEM_DATA_MODULE_NAME, itemDataModule)
		end
		local optionDataModule = dataTableFolder:FindFirstChild(OPTION_DATA_MODULE_NAME)
		if optionDataModule and optionDataModule:IsA("ModuleScript") then
			replicateDataTableModuleForClients(OPTION_DATA_MODULE_NAME, optionDataModule)
		end
		local stageDataModule = dataTableFolder:FindFirstChild(STAGE_DATA_MODULE_NAME)
		if stageDataModule and stageDataModule:IsA("ModuleScript") then
			replicateDataTableModuleForClients(STAGE_DATA_MODULE_NAME, stageDataModule)
		end
		local petDataModule = dataTableFolder:FindFirstChild(PET_DATA_MODULE_NAME)
		if petDataModule and petDataModule:IsA("ModuleScript") then
			replicateDataTableModuleForClients(PET_DATA_MODULE_NAME, petDataModule)
		end
	end

	stringDataRaw = loadStringDataFromServerStorage()
	if stringDataRaw ~= nil then
		print("[DataManager] StringData 원본 로드 완료")
	else
		warn("[DataManager] StringData 원본 없음 — StringHelper fallback 사용")
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	game:BindToClose(function()
		saveAllDirty()
	end)

	startAutoSaveLoop()
	print("[DataManager] 초기화 완료")
end

function DataManager.isLoaded(player: Player): boolean
	local session = getSession(player.UserId)
	return session ~= nil and session.loaded
end

function DataManager.waitUntilLoaded(player: Player, timeoutSec: number?): boolean
	local timeout = timeoutSec or LOAD_TIMEOUT_SEC
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		if DataManager.isLoaded(player) then
			return true
		end
		if not player.Parent then
			return false
		end
		task.wait(0.1)
	end
	warn("[DataManager] 데이터 로드 타임아웃:", player.Name)
	return false
end

function DataManager.getSavedData(player: Player): SavedPlayerData?
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		return nil
	end
	return session.data
end

function DataManager.getCurrency(player: Player, currencyType: CurrencyType): number
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		return 0
	end
	if currencyType == "Gem" then
		return session.data.Currency.Gem
	end
	if currencyType == "Gold" then
		return session.data.Currency.Gold
	end
	if currencyType == "BattlePassPoint" then
		return session.data.Currency.BattlePassPoint
	end
	return 0
end

function DataManager.getGem(player: Player): number
	return DataManager.getCurrency(player, "Gem")
end

function DataManager.getGold(player: Player): number
	return DataManager.getCurrency(player, "Gold")
end

function DataManager.getBattlePassPoint(player: Player): number
	return DataManager.getCurrency(player, "BattlePassPoint")
end

function DataManager.addCurrency(player: Player, currencyType: CurrencyType, amount: number): boolean
	local delta = normalizeAmount(amount)
	if not delta then
		return false
	end
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		warn("[DataManager] addCurrency: 데이터 미로드", player.Name)
		return false
	end

	if currencyType == "Gem" then
		session.data.Currency.Gem += delta
	elseif currencyType == "Gold" then
		session.data.Currency.Gold += delta
	elseif currencyType == "BattlePassPoint" then
		session.data.Currency.BattlePassPoint += delta
		session.data.BattlePass = applyBattlePassXpByPoint(session.data.BattlePass, delta)
	else
		return false
	end

	markDirty(session)
	syncCurrencyAttributes(player, session.data.Currency)

	if currencyType == "Gold" then
		notifyGoldAdded(player, delta)
	end

	return true
end

function DataManager.addItem(player: Player, itemType: Types.ItemType, amount: number): boolean
	local delta = normalizeAmount(amount)
	if not delta then
		return false
	end
	local normalizedType = Types.normalizeItemType(itemType)
	if not normalizedType then
		return false
	end
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		warn("[DataManager] addItem: 데이터 미로드", player.Name)
		return false
	end

	local current = session.data.Inventory.Item[normalizedType] or 0
	session.data.Inventory.Item[normalizedType] = current + delta
	markDirty(session)
	return true
end

function DataManager.getItemCount(player: Player, itemType: Types.ItemType): number
	local normalizedType = Types.normalizeItemType(itemType)
	if not normalizedType then
		return 0
	end
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		return 0
	end
	return session.data.Inventory.Item[normalizedType] or 0
end

--- 보유 수량이 amount 미만이면 false(소모 안 함). 성공 시 amount만큼 차감 후 true.
function DataManager.consumeItem(player: Player, itemType: Types.ItemType, amount: number): boolean
	local cost = normalizeAmount(amount)
	if not cost then
		return false
	end
	local normalizedType = Types.normalizeItemType(itemType)
	if not normalizedType then
		return false
	end
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		warn("[DataManager] consumeItem: 데이터 미로드", player.Name)
		return false
	end

	local current = session.data.Inventory.Item[normalizedType] or 0
	if current < cost then
		return false
	end

	session.data.Inventory.Item[normalizedType] = current - cost
	markDirty(session)
	return true
end

function DataManager.spendCurrency(player: Player, currencyType: CurrencyType, amount: number): boolean
	local cost = normalizeAmount(amount)
	if not cost then
		return false
	end
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		warn("[DataManager] spendCurrency: 데이터 미로드", player.Name)
		return false
	end

	local balance = if currencyType == "Gem"
		then session.data.Currency.Gem
		elseif currencyType == "Gold" then session.data.Currency.Gold
		elseif currencyType == "BattlePassPoint" then session.data.Currency.BattlePassPoint
		else nil
	if balance == nil or balance < cost then
		return false
	end

	if currencyType == "Gem" then
		session.data.Currency.Gem -= cost
	elseif currencyType == "Gold" then
		session.data.Currency.Gold -= cost
	else
		session.data.Currency.BattlePassPoint -= cost
	end

	markDirty(session)
	syncCurrencyAttributes(player, session.data.Currency)
	return true
end

function DataManager.hasCostume(player: Player, costumeId: string): boolean
	if typeof(costumeId) ~= "string" or costumeId == "" then
		return false
	end
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		return false
	end
	for _, owned in session.data.Inventory.Costume do
		if owned == costumeId then
			return true
		end
	end
	return false
end

function DataManager.getOwnedCostumeIds(player: Player): { string }
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		return {}
	end
	return table.clone(session.data.Inventory.Costume)
end

function DataManager.addCostume(player: Player, costumeId: string): boolean
	if typeof(costumeId) ~= "string" or costumeId == "" then
		return false
	end
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		warn("[DataManager] addCostume: 데이터 미로드", player.Name)
		return false
	end
	if DataManager.hasCostume(player, costumeId) then
		return true
	end
	table.insert(session.data.Inventory.Costume, costumeId)
	markDirty(session)
	return true
end

function DataManager.getEquippedCostume(player: Player): string?
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		return nil
	end
	return session.data.Inventory.EquippedCostume
end

--- costumeId가 nil이면 장착 해제. 소유 여부 검증은 호출 측(CostumeHelper)의 책임.
function DataManager.setEquippedCostume(player: Player, costumeId: string?): boolean
	if costumeId ~= nil and (typeof(costumeId) ~= "string" or costumeId == "") then
		return false
	end
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		warn("[DataManager] setEquippedCostume: 데이터 미로드", player.Name)
		return false
	end
	session.data.Inventory.EquippedCostume = costumeId
	markDirty(session)
	return true
end

function DataManager.getDailyRewardEntry(player: Player, datasetIndex: number): DailyRewardDatasetProgress?
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		return nil
	end
	local entry = session.data.DailyReward[datasetIndex]
	if not entry then
		return nil
	end
	return {
		currentDay = entry.currentDay,
		claimedDays = table.clone(entry.claimedDays),
		lastAttendanceTime = entry.lastAttendanceTime,
	}
end

function DataManager.setDailyRewardEntry(player: Player, datasetIndex: number, entry: DailyRewardDatasetProgress): boolean
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		warn("[DataManager] setDailyRewardEntry: 데이터 미로드", player.Name)
		return false
	end
	if datasetIndex ~= datasetIndex or math.floor(datasetIndex) ~= datasetIndex then
		return false
	end
	if entry.currentDay < 1 or entry.currentDay > DAILY_REWARD_DAYS then
		return false
	end
	if typeof(entry.lastAttendanceTime) ~= "number" or entry.lastAttendanceTime <= 0 then
		return false
	end

	local claimedDays = normalizeClaimedDays(entry.claimedDays)
	session.data.DailyReward[datasetIndex] = {
		currentDay = entry.currentDay,
		claimedDays = claimedDays,
		lastAttendanceTime = entry.lastAttendanceTime,
	}
	markDirty(session)
	return true
end

function DataManager.getMissionProgress(player: Player): MissionProgress?
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		return nil
	end
	local mission = session.data.Mission
	return {
		missionDayStartTime = mission.missionDayStartTime,
		selectedIndices = table.clone(mission.selectedIndices),
		progress = table.clone(mission.progress),
		claimed = table.clone(mission.claimed),
	}
end

function DataManager.setMissionProgress(player: Player, progress: MissionProgress): boolean
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		warn("[DataManager] setMissionProgress: 데이터 미로드", player.Name)
		return false
	end
	if typeof(progress.missionDayStartTime) ~= "number" then
		return false
	end

	session.data.Mission = mergeMissionProgressRecords(session.data.Mission, progress)
	markDirty(session)
	return true
end

function DataManager.getAchievementProgress(player: Player): AchievementProgress?
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		return nil
	end
	local achievement = session.data.Achievement
	return {
		progress = table.clone(achievement.progress),
		claimed = table.clone(achievement.claimed),
	}
end

function DataManager.setAchievementProgress(player: Player, progress: AchievementProgress): boolean
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		warn("[DataManager] setAchievementProgress: 데이터 미로드", player.Name)
		return false
	end

	session.data.Achievement = mergeAchievementProgressRecords(session.data.Achievement, progress)
	markDirty(session)
	return true
end

function DataManager.getBattlePassProgress(player: Player): BattlePassProgress?
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		return nil
	end
	local battlePass = session.data.BattlePass
	return {
		level = battlePass.level,
		xp = battlePass.xp,
		freeClaimedLevel = battlePass.freeClaimedLevel,
		premiumClaimedLevel = battlePass.premiumClaimedLevel,
		maxLevelPremiumRewardClaimed = battlePass.maxLevelPremiumRewardClaimed,
	}
end

function DataManager.setBattlePassProgress(player: Player, progress: BattlePassProgress): boolean
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		warn("[DataManager] setBattlePassProgress: 데이터 미로드", player.Name)
		return false
	end
	if typeof(progress.level) ~= "number" then
		return false
	end
	if typeof(progress.xp) ~= "number" then
		return false
	end
	if typeof(progress.freeClaimedLevel) ~= "number" then
		return false
	end
	if typeof(progress.premiumClaimedLevel) ~= "number" then
		return false
	end
	if typeof(progress.maxLevelPremiumRewardClaimed) ~= "boolean" then
		return false
	end

	session.data.BattlePass = {
		level = math.max(0, math.floor(progress.level)),
		xp = math.max(0, math.floor(progress.xp)),
		freeClaimedLevel = math.max(0, math.floor(progress.freeClaimedLevel)),
		premiumClaimedLevel = math.max(0, math.floor(progress.premiumClaimedLevel)),
		maxLevelPremiumRewardClaimed = progress.maxLevelPremiumRewardClaimed,
	}
	markDirty(session)
	return true
end

function DataManager.getRelicProgress(player: Player): RelicProgress?
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		return nil
	end
	return cloneRelicProgress(session.data.Relics)
end

function DataManager.getRelicProgressEntry(player: Player, relicId: number): RelicProgressEntry?
	if typeof(relicId) ~= "number" or relicId ~= relicId then
		return nil
	end
	local id = math.floor(relicId)
	if id < 1 then
		return nil
	end
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		return nil
	end
	local entry = session.data.Relics[id]
	if not entry then
		return {
			level = 0,
			xp = 0,
		}
	end
	return {
		level = entry.level,
		xp = entry.xp,
	}
end

function DataManager.setRelicProgressEntry(player: Player, relicId: number, entry: RelicProgressEntry): boolean
	if typeof(relicId) ~= "number" or relicId ~= relicId then
		return false
	end
	local id = math.floor(relicId)
	if id < 1 then
		return false
	end
	local normalized = normalizeRelicProgressEntry(entry)
	if not normalized then
		return false
	end
	local session = getSession(player.UserId)
	if not session or not session.loaded then
		warn("[DataManager] setRelicProgressEntry: 데이터 미로드", player.Name)
		return false
	end
	session.data.Relics[id] = {
		level = normalized.level,
		xp = normalized.xp,
	}
	markDirty(session)
	return true
end

function DataManager.getRelicDataRaw(): any?
	return relicDataRaw
end

function DataManager.getDailyRewardDataRaw(): any?
	return dailyRewardDataRaw
end

function DataManager.getMissionDataRaw(): any?
	return missionDataRaw
end

function DataManager.getAchievementDataRaw(): any?
	return achievementDataRaw
end

function DataManager.getStringDataRaw(): any?
	return stringDataRaw
end

function DataManager.getShopDataRaw(): any?
	return shopDataRaw
end

function DataManager.getBattlePassDataRaw(): any?
	return battlePassDataRaw
end

function DataManager.getGrantDataRaw(): any?
	return grantDataRaw
end

return DataManager
