local CURRENCY_TYPES = { "Gem", "Gold", "BattlePassPoint" } :: { "Gem" | "Gold" | "BattlePassPoint" }
export type CurrencyType = typeof(CURRENCY_TYPES[1])

export type CurrencyBalance = {
	Gem: number,
	Gold: number,
	BattlePassPoint: number,
}

local ITEM_TYPES = {
	"SpeedUp",
	"FeverGaugeUp",
	"FeverGaugeMax",
	"RelicNormalKey",
	"RelicSpecialKey",
} :: { "SpeedUp" | "FeverGaugeUp" | "FeverGaugeMax" | "RelicNormalKey" | "RelicSpecialKey" }
export type ItemType = typeof(ITEM_TYPES[1])

export type ItemInventory = {
	[ItemType]: number,
}

local OPTION_TYPES = {
	"FeverGaugeAutoCharge",
	"FeverDurationUp",
	"FeverGaugeGainBonus",
	"FeverGaugeStageStart",
	"StageRewardCurrencyUp",
	"AttackSpeedUp",
	"StageRewardPassExpUp",
	"MoveSpeedUp",
	"XpAutoCharge",
	"XpChargeOnLevelUp",
	"XpGainBonusOnDestroy",
	"XpStageStart",
} :: {
	"FeverGaugeAutoCharge"
		| "FeverDurationUp"
		| "FeverGaugeGainBonus"
		| "FeverGaugeStageStart"
		| "StageRewardCurrencyUp"
		| "AttackSpeedUp"
		| "StageRewardPassExpUp"
		| "MoveSpeedUp"
		| "XpAutoCharge"
		| "XpChargeOnLevelUp"
		| "XpGainBonusOnDestroy"
		| "XpStageStart"
}
export type OptionType = typeof(OPTION_TYPES[1])

export type OptionTypeDefinition = {
	stringKey: string,
	statCount: number, -- 1 또는 2 — 포맷에서 쓰는 stat 개수
}

export type OptionDataSource = {
	types: { [OptionType]: OptionTypeDefinition },
}

export type InventoryType = "Item" | "Costume"

export type InventoryData = {
	Item: ItemInventory,
	Costume: { string },
	EquippedCostume: string?,
}

export type GrantedCampaigns = {
	[string]: boolean,
}

export type RewardType = "Currency" | "Relic" | "Item" | "Costume"

local DEFAULT_CURRENCY_BALANCE: CurrencyBalance = {
	Gem = 0,
	Gold = 0,
	BattlePassPoint = 0,
}

local REWARD_TYPES: { RewardType } = { "Currency", "Relic", "Item", "Costume" }

local INVENTORY_TYPES: { InventoryType } = { "Item", "Costume" }

export type CurrencyReward = {
	rewardType: "Currency",
	currencyType: CurrencyType,
	amount: number,
}

export type RelicReward = {
	rewardType: "Relic",
	id: number,
}

export type ItemReward = {
	rewardType: "Item",
	itemType: ItemType,
	amount: number,
}

export type CostumeReward = {
	rewardType: "Costume",
	id: string,
}

export type Reward = CurrencyReward | RelicReward | ItemReward | CostumeReward

export type DailyRewardDatasetProgress = {
	currentDay: number,
	claimedDays: { boolean },
	lastAttendanceTime: number,
}

export type DailyRewardProgress = {
	[number]: DailyRewardDatasetProgress,
}

export type MissionProgress = {
	missionDayStartTime: number,
	selectedIndices: { number },
	progress: { [number]: number },
	claimed: { [number]: boolean },
}

export type AchievementProgress = {
	progress: { [number]: number },
	claimed: { [number]: boolean },
}

export type BattlePassProgress = {
	level: number,
	xp: number,
	freeClaimedLevel: number,
	premiumClaimedLevel: number,
	maxLevelPremiumRewardClaimed: boolean,
}

export type RelicProgressEntry = {
	level: number,
	xp: number,
}

export type RelicProgress = {
	[number]: RelicProgressEntry,
}

export type SavedPlayerData = {
	DataVersion: number,
	Currency: CurrencyBalance,
	StageProgress: { [number]: boolean },
	DailyReward: DailyRewardProgress,
	Inventory: InventoryData,
	Relics: RelicProgress,
	GrantedCampaigns: GrantedCampaigns,
	Mission: MissionProgress,
	Achievement: AchievementProgress,
	BattlePass: BattlePassProgress,
}

export type PlayerData = {
	Name: string,
	UserId: number,
	JoinTime: number,
	StageProgress: { [number]: boolean },
	Currency: CurrencyBalance?,
}

export type StageClearRewardEntry = {
	currencyType: CurrencyType,
	amount: number,
}

export type StageDefinition = {
	stageNumber: number,
	nameKey: string,
	timeLimitSec: number,
	mapImageAssetId: string?,
}

export type StageDataSource = {
	stages: { [number]: StageDefinition },
	clearRewardByDifficulty: { [number]: { StageClearRewardEntry } },
}

export type DailyRewardEntry = {
	currencyType: CurrencyType,
	amount: number,
}

export type DailyRewardDataset = {
	index: number,
	name: string,
	rewards: { DailyRewardEntry },
}

export type DailyRewardDataSource = {
	activeDatasetIndex: number,
	datasets: { [number]: DailyRewardDataset },
}

export type RelicGrade = "A" | "B" | "C" | "D"

export type RelicAbilityLevelStat = {
	stat1: number,
	stat2: number?,
}

export type RelicAbility = {
	type: OptionType, -- OptionData.types 키
	levels: { [number]: RelicAbilityLevelStat }, -- 1~4
}

export type RelicDefinition = {
	id: number,
	name: string,
	grade: RelicGrade,
	icon: string,
	abilities: { RelicAbility },
}

export type SummonCostEntry = {
	currencyType: CurrencyType,
	amount: number,
}

export type RelicSummonPoolCosts = {
	[number]: SummonCostEntry,
}

export type RelicSummonCosts = {
	Normal: RelicSummonPoolCosts,
	Special: RelicSummonPoolCosts,
}

export type RelicLevelXpRequired = {
	[number]: number,
}

export type RelicSetLevelEntry = {
	stat1: number,
	requiredRelicLevel: number,
}

export type RelicSetEffect = {
	type: OptionType, -- OptionData.types 키
	levels: { [number]: RelicSetLevelEntry }, -- 1~4
}

export type RelicSetDefinition = {
	grade: RelicGrade,
	relicIds: { number },
	effect: RelicSetEffect,
}

export type RelicDataSource = {
	relics: { [number]: RelicDefinition },
	levelXpRequired: RelicLevelXpRequired,
	summons: RelicSummonCosts?,
	sets: { [string]: RelicSetDefinition }?,
}

export type MissionRewardEntry = {
	currencyType: CurrencyType,
	amount: number,
}

export type MissionDefinition = {
	index: number,
	stringKey: string,
	progressCnt: number,
	rewards: { MissionRewardEntry },
}

export type MissionDataSource = {
	missions: { [number]: MissionDefinition },
}

export type AchievementRewardEntry = {
	currencyType: CurrencyType,
	amount: number,
}

export type AchievementType =
	"StageClear"
	| "PropDestroy"
	| "NpcDestroy"
	| "TargetPropDestroy"
	| "Fever"
	| "StageTimeClear"
	| "MissionClear"
	| "GetGold"
	| "PartyPlay"
	| "TargetStageClear"
	| "Attendance"
	| "RelicSummon"
	| "RelicGradeCollect"

export type AchievementTypeDefinition = {
	stringKey: string,
	icon: string,
	iconByCondition: { [string]: string }?,
}

export type AchievementDefinition = {
	index: number,
	type: AchievementType,
	condition: string?,
	progressCnt: number,
	stringKey: string,
	icon: string,
	rewards: { AchievementRewardEntry },
}

export type AchievementEventContext = {
	stageNumber: number?,
	clearTimeSec: number?,
	targetKey: string?,
	partySize: number?,
	relicGrade: RelicGrade?,
	goldAmount: number?,
	amount: number?,
}

export type AchievementDataSource = {
	types: { [AchievementType]: AchievementTypeDefinition },
	achievements: { [number]: AchievementDefinition },
}

export type ShopCurrencyRewardEntry = {
	currencyType: CurrencyType,
	amount: number,
}

export type ShopBattlePassLevelRewardEntry = {
	rewardType: "BattlePassLevel",
	amount: number,
}

export type ShopRewardEntry = ShopCurrencyRewardEntry | ShopBattlePassLevelRewardEntry

export type ShopProductDefinition = {
	index: number,
	itemKey: string,
	productId: number,
	rewards: { ShopRewardEntry },
	hidden: boolean?,
}

export type ShopDataSource = {
	products: { [number]: ShopProductDefinition },
}

export type BattlePassLevelDefinition = {
	level: number,
	xpRequired: number,
	freeReward: Reward,
	premiumReward: Reward,
}

export type BattlePassDataSource = {
	seasonIndex: number,
	seasonStartTime: string,
	seasonEndTime: string,
	premiumGamePassId: number,
	jumpLevelProductId: number,
	startLevel: number,
	maxLevel: number,
	maxLevelPremiumReward: Reward,
	levels: { [number]: BattlePassLevelDefinition },
}

export type GrantItemEntry = {
	itemType: ItemType,
	itemAmount: number,
}

export type GrantCampaignDefinition = {
	id: string,
	enabled: boolean,
	items: { GrantItemEntry },
}

export type GrantDataSource = {
	campaigns: { GrantCampaignDefinition },
}

local COSTUME_COST_TYPES = { "Gem", "Gold", "BattlePassPoint", "Robux" } :: {
	"Gem" | "Gold" | "BattlePassPoint" | "Robux"
}
export type CostumeCostType = typeof(COSTUME_COST_TYPES[1])

export type CostumeDefinition = {
	id: string,
	modelName: string,
	iconAssetId: string,
	costType: CostumeCostType,
	costAmount: number?, -- costType ~= "Robux"일 때만 사용
	productId: number?, -- costType == "Robux"일 때만 사용
}

export type CostumeDataSource = {
	costumes: { [string]: CostumeDefinition },
}

local function buildStringSet(values: { any }): { [string]: true }
	local set: { [string]: true } = {}
	for _, value in values do
		if typeof(value) == "string" then
			set[value] = true
		end
	end
	return set
end

local CURRENCY_TYPE_SET = buildStringSet(CURRENCY_TYPES)
local ITEM_TYPE_SET = buildStringSet(ITEM_TYPES)
local REWARD_TYPE_SET = buildStringSet(REWARD_TYPES)
local INVENTORY_TYPE_SET = buildStringSet(INVENTORY_TYPES)
local OPTION_TYPE_SET = buildStringSet(OPTION_TYPES)
local COSTUME_COST_TYPE_SET = buildStringSet(COSTUME_COST_TYPES)

local Types = {}

Types.DEFAULT_CURRENCY_BALANCE = DEFAULT_CURRENCY_BALANCE
Types.CURRENCY_TYPES = CURRENCY_TYPES
Types.ITEM_TYPES = ITEM_TYPES
Types.REWARD_TYPES = REWARD_TYPES
Types.INVENTORY_TYPES = INVENTORY_TYPES
Types.OPTION_TYPES = OPTION_TYPES
Types.COSTUME_COST_TYPES = COSTUME_COST_TYPES

function Types.normalizeCurrencyType(raw: any): CurrencyType?
	if typeof(raw) == "string" and CURRENCY_TYPE_SET[raw] then
		return raw :: CurrencyType
	end
	return nil
end

function Types.normalizeItemType(raw: any): ItemType?
	if typeof(raw) == "string" and ITEM_TYPE_SET[raw] then
		return raw :: ItemType
	end
	return nil
end

function Types.normalizeOptionType(raw: any): OptionType?
	if typeof(raw) == "string" and OPTION_TYPE_SET[raw] then
		return raw :: OptionType
	end
	return nil
end

function Types.normalizeCostumeCostType(raw: any): CostumeCostType?
	if typeof(raw) == "string" and COSTUME_COST_TYPE_SET[raw] then
		return raw :: CostumeCostType
	end
	return nil
end

function Types.normalizeRewardType(raw: any): RewardType?
	if raw == "Pet" then
		return "Relic"
	end
	if typeof(raw) == "string" and REWARD_TYPE_SET[raw] then
		return raw :: RewardType
	end
	return nil
end

function Types.normalizeInventoryType(raw: any): InventoryType?
	if typeof(raw) == "string" and INVENTORY_TYPE_SET[raw] then
		return raw :: InventoryType
	end
	return nil
end

function Types.createDefaultCurrencyBalance(): CurrencyBalance
	return table.clone(DEFAULT_CURRENCY_BALANCE)
end

return Types
