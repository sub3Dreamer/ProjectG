--[[
	AchievementHelper (shared)

	마스터 데이터: DataManager.getAchievementDataRaw() (서버) / ReplicatedStorage.DataTable.AchievementData (클라이언트)
	AchievementData: types (stringKey/icon) + achievements (type, condition?, progressCnt, rewards)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DataManager = require(Shared.Managers.DataManager)
local StringHelper = require(Shared.Helpers.StringHelper)
local Types = require(Shared.Types)

local AchievementHelper = {}

export type CurrencyType = Types.CurrencyType
export type AchievementType = Types.AchievementType
export type AchievementRewardEntry = Types.AchievementRewardEntry
export type AchievementTypeDefinition = Types.AchievementTypeDefinition
export type AchievementDefinition = Types.AchievementDefinition
export type AchievementDataSource = Types.AchievementDataSource
export type AchievementEventContext = Types.AchievementEventContext

local GET_SNAPSHOT_REMOTE_NAME = "GetAchievementSnapshot"
local CLAIM_REMOTE_NAME = "ClaimAchievementReward"

local VALID_ACHIEVEMENT_TYPES: { [AchievementType]: boolean } = {
	StageClear = true,
	PropDestroy = true,
	NpcDestroy = true,
	TargetPropDestroy = true,
	Fever = true,
	StageTimeClear = true,
	MissionClear = true,
	GetGold = true,
	PartyPlay = true,
	TargetStageClear = true,
	Attendance = true,
	RelicSummon = true,
	RelicGradeCollect = true,
}

local CONDITION_REQUIRED: { [AchievementType]: boolean } = {
	StageTimeClear = true,
	TargetStageClear = true,
	TargetPropDestroy = true,
	PartyPlay = true,
	RelicGradeCollect = true,
}

local initialized = false
local runtime: AchievementDataSource? = nil
local achievementsByType: { [AchievementType]: { number } } = {}

local function normalizeAchievementIndex(raw: any): number?
	if typeof(raw) ~= "number" or raw ~= raw then
		return nil
	end
	local index = math.floor(raw)
	if index < 1 then
		return nil
	end
	return index
end

local function normalizeAchievementType(raw: any): AchievementType?
	if typeof(raw) ~= "string" or not VALID_ACHIEVEMENT_TYPES[raw :: any] then
		return nil
	end
	return raw :: AchievementType
end

local function normalizeCondition(raw: any): string?
	if raw == nil then
		return nil
	end
	if typeof(raw) ~= "string" then
		return nil
	end
	if raw == "" then
		return nil
	end
	return raw
end

local function normalizeRewardAmount(raw: any): number?
	if typeof(raw) ~= "number" or raw ~= raw then
		return nil
	end
	local amount = math.floor(raw)
	if amount <= 0 then
		return nil
	end
	return amount
end

local function normalizeRewardEntry(raw: any): AchievementRewardEntry?
	if typeof(raw) ~= "table" then
		return nil
	end
	local currencyType = Types.normalizeCurrencyType(raw.currencyType)
	local amount = normalizeRewardAmount(raw.amount)
	if not currencyType or not amount then
		return nil
	end
	return {
		currencyType = currencyType,
		amount = amount,
	}
end

local function normalizeRewards(raw: any): { AchievementRewardEntry }?
	if typeof(raw) ~= "table" then
		return nil
	end
	local rewards: { AchievementRewardEntry } = {}
	for _, rewardRaw in raw do
		local entry = normalizeRewardEntry(rewardRaw)
		if not entry then
			return nil
		end
		table.insert(rewards, entry)
	end
	if #rewards == 0 then
		return nil
	end
	return rewards
end

local function normalizeProgressCount(raw: any): number?
	if typeof(raw) ~= "number" or raw ~= raw then
		return nil
	end
	local progressCnt = math.floor(raw)
	if progressCnt <= 0 then
		return nil
	end
	return progressCnt
end

local function cloneRewards(rewards: { AchievementRewardEntry }): { AchievementRewardEntry }
	local out: { AchievementRewardEntry } = {}
	for _, reward in rewards do
		table.insert(out, {
			currencyType = reward.currencyType,
			amount = reward.amount,
		})
	end
	return out
end

local function cloneAchievementDefinition(achievement: AchievementDefinition): AchievementDefinition
	return {
		index = achievement.index,
		type = achievement.type,
		condition = achievement.condition,
		progressCnt = achievement.progressCnt,
		stringKey = achievement.stringKey,
		icon = achievement.icon,
		rewards = cloneRewards(achievement.rewards),
	}
end

local function normalizeIconByCondition(raw: any): { [string]: string }?
	if typeof(raw) ~= "table" then
		return nil
	end

	local out: { [string]: string } = {}
	for key, value in raw do
		if typeof(value) ~= "string" or value == "" then
			continue
		end
		local condKey = if typeof(key) == "string" then key else tostring(key)
		if condKey ~= "" then
			out[condKey] = value
		end
	end

	if next(out) == nil then
		return nil
	end
	return out
end

local function resolveAchievementIcon(typeDef: AchievementTypeDefinition, condition: string?): string
	if condition and typeDef.iconByCondition then
		local mapped = typeDef.iconByCondition[condition]
		if typeof(mapped) == "string" and mapped ~= "" then
			return mapped
		end
	end
	return typeDef.icon
end

local function normalizeTypes(raw: any): { [AchievementType]: AchievementTypeDefinition }?
	if typeof(raw) ~= "table" then
		return nil
	end

	local types: { [AchievementType]: AchievementTypeDefinition } = {}
	for typeName, typeRaw in raw do
		local achievementType = normalizeAchievementType(typeName)
		if not achievementType or typeof(typeRaw) ~= "table" then
			continue
		end
		local stringKey = if typeof(typeRaw.stringKey) == "string" and typeRaw.stringKey ~= ""
			then typeRaw.stringKey
			else nil
		local icon = if typeof(typeRaw.icon) == "string" and typeRaw.icon ~= "" then typeRaw.icon else nil
		if not stringKey or not icon then
			warn("[AchievementHelper] types." .. tostring(typeName), "stringKey/icon 없음")
			continue
		end
		types[achievementType] = {
			stringKey = stringKey,
			icon = icon,
			iconByCondition = normalizeIconByCondition(typeRaw.iconByCondition),
		}
	end

	if next(types) == nil then
		return nil
	end
	return types
end

local function normalizeAchievementRow(
	raw: any,
	tableKeyIndex: number?,
	types: { [AchievementType]: AchievementTypeDefinition }
): AchievementDefinition?
	if typeof(raw) ~= "table" then
		return nil
	end

	local indexFromRow = normalizeAchievementIndex(raw.index)
	local index = tableKeyIndex or indexFromRow
	if index == nil then
		return nil
	end
	if indexFromRow ~= nil and indexFromRow ~= index then
		warn(
			string.format(
				"[AchievementHelper] AchievementData index 불일치 (key=%d, row.index=%d) — key 사용",
				index,
				indexFromRow
			)
		)
	end

	local achievementType = normalizeAchievementType(raw.type)
	if not achievementType then
		warn("[AchievementHelper] 업적", index, "type 없음/잘못됨")
		return nil
	end

	local typeDef = types[achievementType]
	if not typeDef then
		warn("[AchievementHelper] 업적", index, "types." .. achievementType, "없음")
		return nil
	end

	local condition = normalizeCondition(raw.condition)
	if CONDITION_REQUIRED[achievementType] and not condition then
		warn("[AchievementHelper] 업적", index, achievementType, "condition 필수")
		return nil
	end

	local progressCnt = normalizeProgressCount(raw.progressCnt)
	local rewards = normalizeRewards(raw.rewards)
	if not progressCnt or not rewards then
		return nil
	end

	return {
		index = index,
		type = achievementType,
		condition = condition,
		progressCnt = progressCnt,
		stringKey = typeDef.stringKey,
		icon = resolveAchievementIcon(typeDef, condition),
		rewards = rewards,
	}
end

local function rebuildAchievementsByType(achievements: { [number]: AchievementDefinition })
	achievementsByType = {}
	for index, achievement in achievements do
		local list = achievementsByType[achievement.type]
		if not list then
			list = {}
			achievementsByType[achievement.type] = list
		end
		table.insert(list, index)
	end
	for _, list in achievementsByType do
		table.sort(list)
	end
end

local function buildFallbackSource(): AchievementDataSource
	local goldType: AchievementType = "GetGold"
	local types: { [AchievementType]: AchievementTypeDefinition } = {
		[goldType] = {
			stringKey = "Achievement_GetGold",
			icon = "Default",
		},
	}
	local achievements: { [number]: AchievementDefinition } = {
		[1] = {
			index = 1,
			type = goldType,
			condition = nil,
			progressCnt = 1,
			stringKey = types[goldType].stringKey,
			icon = types[goldType].icon,
			rewards = {
				{ currencyType = "Gold", amount = 1000 },
			},
		},
	}
	rebuildAchievementsByType(achievements)
	return {
		types = types,
		achievements = achievements,
	}
end

local function normalizeSource(raw: any): AchievementDataSource?
	if typeof(raw) ~= "table" or typeof(raw.achievements) ~= "table" then
		return nil
	end

	local types = normalizeTypes(raw.types)
	if not types then
		warn("[AchievementHelper] AchievementData.types 없음/형식 오류")
		return nil
	end

	local achievements: { [number]: AchievementDefinition } = {}
	for key, achievementRaw in raw.achievements do
		local achievementIndex = normalizeAchievementIndex(if typeof(key) == "number" then key else tonumber(key))
		if achievementIndex == nil then
			continue
		end
		local achievement = normalizeAchievementRow(achievementRaw, achievementIndex, types)
		if achievement then
			achievements[achievementIndex] = achievement
		end
	end

	if next(achievements) == nil then
		return nil
	end

	rebuildAchievementsByType(achievements)
	return {
		types = types,
		achievements = achievements,
	}
end

local function loadAchievementDataRaw(): any?
	if RunService:IsServer() then
		local raw = DataManager.getAchievementDataRaw()
		if raw ~= nil then
			return raw
		end
		local ok, result = pcall(function()
			return require(ServerStorage:WaitForChild("DataTable"):WaitForChild("AchievementData"))
		end)
		if ok then
			return result
		end
		return nil
	end

	local ok, result = pcall(function()
		return require(ReplicatedStorage:WaitForChild("DataTable"):WaitForChild("AchievementData"))
	end)
	if ok then
		return result
	end
	return nil
end

local function getRuntime(): AchievementDataSource
	if not runtime then
		local raw = loadAchievementDataRaw()
		local normalized = if raw ~= nil then normalizeSource(raw) else nil
		if normalized then
			runtime = normalized
			print(string.format("[AchievementHelper] AchievementData 로드 (%d개)", AchievementHelper.getAchievementCount()))
		else
			runtime = buildFallbackSource()
			warn("[AchievementHelper] AchievementData 없음/형식 오류 — fallback 사용 (src/datatable/AchievementData.luau)")
		end
	end
	return runtime :: AchievementDataSource
end

function AchievementHelper.getProgressGoal(achievement: AchievementDefinition): number
	if achievement.type == "StageTimeClear" then
		return 1
	end
	return achievement.progressCnt
end

function AchievementHelper.formatTitle(achievement: AchievementDefinition, locale: string): string
	local template = StringHelper.get(achievement.stringKey, locale)
	if achievement.condition then
		return StringHelper.format(template, achievement.condition, achievement.progressCnt)
	end
	return StringHelper.format(template, achievement.progressCnt)
end

function AchievementHelper.getTypeDefinition(achievementType: AchievementType): AchievementTypeDefinition?
	return getRuntime().types[achievementType]
end

function AchievementHelper.getAchievement(index: number): AchievementDefinition?
	local achievementIndex = normalizeAchievementIndex(index)
	if achievementIndex == nil then
		return nil
	end
	local achievement = getRuntime().achievements[achievementIndex]
	if not achievement then
		return nil
	end
	return cloneAchievementDefinition(achievement)
end

function AchievementHelper.getAllAchievements(): { [number]: AchievementDefinition }
	local out: { [number]: AchievementDefinition } = {}
	for index, achievement in getRuntime().achievements do
		out[index] = cloneAchievementDefinition(achievement)
	end
	return out
end

function AchievementHelper.getAchievementIndices(): { number }
	local indices: { number } = {}
	for index in getRuntime().achievements do
		table.insert(indices, index)
	end
	table.sort(indices)
	return indices
end

function AchievementHelper.getAchievementIndicesByType(achievementType: AchievementType): { number }
	local list = achievementsByType[achievementType]
	if not list then
		return {}
	end
	local out: { number } = {}
	for _, index in list do
		table.insert(out, index)
	end
	return out
end

function AchievementHelper.getAchievementCount(): number
	local count = 0
	for _ in getRuntime().achievements do
		count += 1
	end
	return count
end

local function newEmptyAchievementProgress(): Types.AchievementProgress
	return {
		progress = {},
		claimed = {},
	}
end

local function isClaimedEntry(value: any): boolean
	return value == true or value == 1
end

local function ensureAchievementState(player: Player): Types.AchievementProgress?
	if not DataManager.isLoaded(player) then
		return nil
	end

	local current = DataManager.getAchievementProgress(player)
	if not current then
		local fresh = newEmptyAchievementProgress()
		DataManager.setAchievementProgress(player, fresh)
		return fresh
	end
	return current
end

local function matchesAchievement(achievement: AchievementDefinition, context: AchievementEventContext?): boolean
	local ctx = context or {}

	if achievement.type == "StageTimeClear" then
		if not achievement.condition or typeof(ctx.stageNumber) ~= "number" then
			return false
		end
		if achievement.condition ~= tostring(ctx.stageNumber) then
			return false
		end
		if typeof(ctx.clearTimeSec) ~= "number" then
			return false
		end
		return ctx.clearTimeSec <= achievement.progressCnt
	end

	if achievement.type == "TargetStageClear" then
		if not achievement.condition or typeof(ctx.stageNumber) ~= "number" then
			return false
		end
		return achievement.condition == tostring(ctx.stageNumber)
	end

	if achievement.type == "TargetPropDestroy" then
		if not achievement.condition or typeof(ctx.targetKey) ~= "string" then
			return false
		end
		return achievement.condition == ctx.targetKey
	end

	if achievement.type == "PartyPlay" then
		if not achievement.condition or typeof(ctx.partySize) ~= "number" then
			return false
		end
		return achievement.condition == tostring(ctx.partySize)
	end

	if achievement.type == "RelicGradeCollect" then
		if not achievement.condition or typeof(ctx.relicGrade) ~= "string" then
			return false
		end
		return achievement.condition == ctx.relicGrade
	end

	return true
end

local function resolveDelta(achievement: AchievementDefinition, context: AchievementEventContext?): number
	if achievement.type == "GetGold" then
		local goldAmount = if context then context.goldAmount else nil
		if typeof(goldAmount) == "number" and goldAmount == goldAmount then
			return math.max(1, math.floor(goldAmount))
		end
		return 0
	end

	local amount = if context then context.amount else nil
	if typeof(amount) == "number" and amount == amount then
		return math.max(1, math.floor(amount))
	end
	return 1
end

function AchievementHelper.incrementProgress(player: Player, achievementIndex: number, amount: number?): boolean
	if not RunService:IsServer() then
		return false
	end
	if not DataManager.isLoaded(player) then
		return false
	end

	local index = normalizeAchievementIndex(achievementIndex)
	if index == nil then
		return false
	end

	local achievement = AchievementHelper.getAchievement(index)
	if not achievement then
		return false
	end

	local state = ensureAchievementState(player)
	if not state then
		return false
	end
	if isClaimedEntry(state.claimed[index]) then
		return false
	end

	local current = state.progress[index] or 0
	local total = AchievementHelper.getProgressGoal(achievement)
	if current >= total then
		return false
	end

	local delta = if typeof(amount) == "number" and amount == amount then math.max(1, math.floor(amount)) else 1
	if achievement.type == "GetGold" then
		if delta <= 0 then
			return false
		end
	end

	local nextCount = math.min(current + delta, total)
	state.progress[index] = nextCount
	local saved = DataManager.setAchievementProgress(player, state)
	if saved then
		print(
			string.format(
				"[AchievementHelper] 업적 %d (%s) 카운팅 (%s): current=%d total=%d",
				index,
				achievement.type,
				player.Name,
				nextCount,
				total
			)
		)
	end
	return saved
end

function AchievementHelper.incrementByType(
	player: Player,
	achievementType: AchievementType,
	context: AchievementEventContext?
): boolean
	if not RunService:IsServer() then
		return false
	end

	local indices = achievementsByType[achievementType]
	if not indices then
		return false
	end

	local anySaved = false
	for _, index in indices do
		local achievement = AchievementHelper.getAchievement(index)
		if achievement and matchesAchievement(achievement, context) then
			local delta = resolveDelta(achievement, context)
			if delta > 0 and AchievementHelper.incrementProgress(player, index, delta) then
				anySaved = true
			end
		end
	end
	return anySaved
end

function AchievementHelper.hasClaimableRewards(player: Player): boolean
	if not DataManager.isLoaded(player) then
		return false
	end
	local state = ensureAchievementState(player)
	if not state then
		return false
	end
	for _, index in AchievementHelper.getAchievementIndices() do
		local achievement = AchievementHelper.getAchievement(index)
		if achievement and not isClaimedEntry(state.claimed[index]) then
			local current = state.progress[index] or 0
			if current >= AchievementHelper.getProgressGoal(achievement) then
				return true
			end
		end
	end
	return false
end

local function buildPlayerSnapshot(player: Player): {
	progress: { [number]: number },
	claimed: { [number]: boolean },
	hasClaimable: boolean,
}?
	local state = ensureAchievementState(player)
	if not state then
		return nil
	end

	local progress: { [number]: number } = {}
	local claimed: { [number]: boolean } = {}
	for _, index in AchievementHelper.getAchievementIndices() do
		progress[index] = state.progress[index] or 0
		claimed[index] = isClaimedEntry(state.claimed[index])
	end

	return {
		progress = progress,
		claimed = claimed,
		hasClaimable = AchievementHelper.hasClaimableRewards(player),
	}
end

function AchievementHelper.claimReward(player: Player, achievementIndex: number): {
	ok: boolean,
	errorMessage: string?,
	rewards: { AchievementRewardEntry }?,
	snapshot: {
		progress: { [number]: number },
		claimed: { [number]: boolean },
		hasClaimable: boolean,
	}?,
}
	local fail = { ok = false, errorMessage = "데이터 미로드", rewards = nil, snapshot = nil }
	if not RunService:IsServer() then
		return fail
	end
	if not DataManager.isLoaded(player) then
		return fail
	end

	local index = normalizeAchievementIndex(achievementIndex)
	if index == nil then
		return { ok = false, errorMessage = "잘못된 업적", rewards = nil, snapshot = nil }
	end

	local achievement = AchievementHelper.getAchievement(index)
	if not achievement then
		return { ok = false, errorMessage = "업적 없음", rewards = nil, snapshot = nil }
	end

	local state = ensureAchievementState(player)
	if not state then
		return fail
	end
	if isClaimedEntry(state.claimed[index]) then
		return { ok = false, errorMessage = "이미 수령함", rewards = nil, snapshot = nil }
	end

	local goal = AchievementHelper.getProgressGoal(achievement)
	local current = state.progress[index] or 0
	if current < goal then
		return { ok = false, errorMessage = "업적 미완료", rewards = nil, snapshot = nil }
	end

	state.claimed[index] = true
	if not DataManager.setAchievementProgress(player, state) then
		state.claimed[index] = nil
		return { ok = false, errorMessage = "진행 저장 실패", rewards = nil, snapshot = nil }
	end

	local grantedRewards: { AchievementRewardEntry } = {}
	for _, reward in achievement.rewards do
		local granted = DataManager.addCurrency(player, reward.currencyType, reward.amount)
		if not granted then
			warn("[AchievementHelper] 재화 지급 실패:", player.Name, "achievement", index, reward.currencyType)
			continue
		end
		table.insert(grantedRewards, {
			currencyType = reward.currencyType,
			amount = reward.amount,
		})
	end

	if #grantedRewards == 0 then
		state.claimed[index] = nil
		DataManager.setAchievementProgress(player, state)
		return { ok = false, errorMessage = "보상 지급 실패", rewards = nil, snapshot = nil }
	end

	if not DataManager.savePlayerNow(player) then
		warn("[AchievementHelper] 즉시 저장 실패:", player.Name, "achievement", index)
	end

	return {
		ok = true,
		errorMessage = nil,
		rewards = grantedRewards,
		snapshot = buildPlayerSnapshot(player),
	}
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
		return buildPlayerSnapshot(player)
	end

	local claimExisting = ReplicatedStorage:FindFirstChild(CLAIM_REMOTE_NAME)
	local claimRemote = if claimExisting and claimExisting:IsA("RemoteFunction")
		then claimExisting
		else Instance.new("RemoteFunction")
	claimRemote.Name = CLAIM_REMOTE_NAME
	claimRemote.Parent = ReplicatedStorage
	claimRemote.OnServerInvoke = function(player: Player, achievementIndexRaw: any)
		if not DataManager.waitUntilLoaded(player) then
			return { ok = false, errorMessage = "데이터 미로드", rewards = nil, snapshot = nil }
		end
		local achievementIndex = normalizeAchievementIndex(achievementIndexRaw)
		if achievementIndex == nil then
			return { ok = false, errorMessage = "잘못된 요청", rewards = nil, snapshot = nil }
		end
		return AchievementHelper.claimReward(player, achievementIndex)
	end
end

function AchievementHelper.init()
	if initialized then
		return
	end
	initialized = true

	getRuntime()

	if RunService:IsServer() then
		bindRemotes()
		DataManager.registerGoldAddedListener(function(player: Player, goldAmount: number)
			AchievementHelper.incrementByType(player, "GetGold", {
				goldAmount = goldAmount,
			})
		end)
	end

	print("[AchievementHelper] 초기화 완료")
end

return AchievementHelper
