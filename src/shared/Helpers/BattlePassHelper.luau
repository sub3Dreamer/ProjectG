--[[
	BattlePassHelper (shared)

	마스터 데이터: DataManager.getBattlePassDataRaw() (서버) / ReplicatedStorage.DataTable.BattlePassData (클라이언트)
	프리미엄 배틀패스(GamePass) 보유 여부:
		서버 MarketplaceService:UserOwnsGamePassAsync(userId) → Player Attribute 동기화
		클라 RemoteFunction GetBattlePassPremiumState 호출
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DataManager = require(Shared.Managers.DataManager)
local TimeHelper = require(Shared.Helpers.TimeHelper)
local RelicHelper = require(Shared.Helpers.RelicHelper)
local Types = require(Shared.Types)

local BattlePassHelper = {}

export type BattlePassLevelDefinition = Types.BattlePassLevelDefinition
export type BattlePassDataSource = Types.BattlePassDataSource
export type Reward = Types.Reward

BattlePassHelper.OWNS_PREMIUM_PASS_ATTRIBUTE = "OwnsPremiumBattlePass"
BattlePassHelper.GET_PREMIUM_STATE_REMOTE_NAME = "GetBattlePassPremiumState"
BattlePassHelper.GET_SNAPSHOT_REMOTE_NAME = "GetBattlePassSnapshot"
BattlePassHelper.CLAIM_REWARDS_REMOTE_NAME = "ClaimBattlePassRewards"

export type BattlePassRewardTrack = "free" | "premium"

export type BattlePassSnapshot = {
	level: number,
	xp: number,
	xpRequiredForNextLevel: number,
	isMaxLevel: boolean,
	freeClaimedLevel: number,
	premiumClaimedLevel: number,
	maxLevelPremiumRewardClaimed: boolean,
	ownsPremiumPass: boolean,
}

export type BattlePassClaimResult = {
	ok: boolean,
	errorMessage: string?,
	rewards: { Reward }?,
	snapshot: BattlePassSnapshot?,
}

local ATTR_OWNS_PREMIUM = BattlePassHelper.OWNS_PREMIUM_PASS_ATTRIBUTE
local GET_STATE_REMOTE_NAME = BattlePassHelper.GET_PREMIUM_STATE_REMOTE_NAME
local GET_SNAPSHOT_REMOTE_NAME = BattlePassHelper.GET_SNAPSHOT_REMOTE_NAME
local CLAIM_REWARDS_REMOTE_NAME = BattlePassHelper.CLAIM_REWARDS_REMOTE_NAME

local initialized = false
local runtime: BattlePassDataSource? = nil
local getStateRemote: RemoteFunction? = nil
local getSnapshotRemote: RemoteFunction? = nil
local claimRewardsRemote: RemoteFunction? = nil

local function normalizePremiumGamePassId(raw: any): number?
	if typeof(raw) ~= "number" or raw ~= raw then
		return nil
	end
	local id = math.floor(raw)
	if id <= 0 then
		return nil
	end
	return id
end

local function normalizeLevel(raw: any): number?
	if typeof(raw) ~= "number" or raw ~= raw then
		return nil
	end
	local level = math.floor(raw)
	if level < 1 then
		return nil
	end
	return level
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

local function normalizeReward(raw: any): Reward?
	if typeof(raw) ~= "table" then
		return nil
	end

	local rewardType = Types.normalizeRewardType(raw.rewardType)
	if rewardType == "Currency" then
		local currencyType = Types.normalizeCurrencyType(raw.currencyType)
		local amount = normalizeRewardAmount(raw.amount)
		if not currencyType or not amount then
			return nil
		end
		return {
			rewardType = "Currency",
			currencyType = currencyType,
			amount = amount,
		}
	end
	if rewardType == "Relic" then
		local relicId = if typeof(raw.id) == "number" and raw.id == raw.id then math.floor(raw.id) else nil
		if relicId == nil or relicId < 1 then
			return nil
		end
		return {
			rewardType = "Relic",
			id = relicId,
		}
	end
	if rewardType == "Item" then
		local itemType = Types.normalizeItemType(raw.itemType)
		local amount = normalizeRewardAmount(raw.amount)
		if not itemType or not amount then
			return nil
		end
		return {
			rewardType = "Item",
			itemType = itemType,
			amount = amount,
		}
	end
	if rewardType == "Costume" then
		if typeof(raw.id) ~= "string" or raw.id == "" then
			return nil
		end
		return {
			rewardType = "Costume",
			id = raw.id,
		}
	end
	return nil
end

local function cloneReward(reward: Reward): Reward
	if reward.rewardType == "Currency" then
		return {
			rewardType = "Currency",
			currencyType = reward.currencyType,
			amount = reward.amount,
		}
	end
	if reward.rewardType == "Relic" then
		return {
			rewardType = "Relic",
			id = reward.id,
		}
	end
	if reward.rewardType == "Item" then
		return {
			rewardType = "Item",
			itemType = reward.itemType,
			amount = reward.amount,
		}
	end
	return {
		rewardType = "Costume",
		id = reward.id,
	}
end

local function normalizeDateString(raw: any): string?
	if typeof(raw) ~= "string" or raw == "" then
		return nil
	end
	if TimeHelper.dateStringToUnix(raw) == nil then
		return nil
	end
	return raw
end

local function normalizeLevelDefinition(raw: any, expectedLevel: number?): BattlePassLevelDefinition?
	if typeof(raw) ~= "table" then
		return nil
	end
	local levelFromRow = normalizeLevel(raw.level)
	local level = expectedLevel or levelFromRow
	if level == nil then
		return nil
	end
	if levelFromRow ~= nil and levelFromRow ~= level then
		warn(
			string.format(
				"[BattlePassHelper] BattlePassData level 불일치 (key=%d, row.level=%d) — key 사용",
				level,
				levelFromRow
			)
		)
	end
	local xpRequired = normalizeRewardAmount(raw.xpRequired)
	local freeReward = normalizeReward(raw.freeReward)
	local premiumReward = normalizeReward(raw.premiumReward)
	if not xpRequired or not freeReward or not premiumReward then
		return nil
	end
	return {
		level = level,
		xpRequired = xpRequired,
		freeReward = freeReward,
		premiumReward = premiumReward,
	}
end

local function buildFallbackSource(): BattlePassDataSource
	local levels: { [number]: BattlePassLevelDefinition } = {}
	for level = 1, 30 do
		local gem50: Reward = {
			rewardType = "Currency",
			currencyType = "Gem",
			amount = 50,
		}
		local gem100: Reward = {
			rewardType = "Currency",
			currencyType = "Gem",
			amount = 100,
		}
		levels[level] = {
			level = level,
			xpRequired = 100 + (level - 1) * 10,
			freeReward = gem50,
			premiumReward = gem100,
		}
	end
	return {
		seasonIndex = 1,
		seasonStartTime = "2026-07-01",
		seasonEndTime = "2026-09-30",
		premiumGamePassId = 1898334892,
		jumpLevelProductId = 3609553930,
		startLevel = 0,
		maxLevel = 30,
		maxLevelPremiumReward = {
			rewardType = "Costume",
			id = "Costume_01",
		},
		levels = levels,
	}
end

local function normalizeSource(raw: any): BattlePassDataSource?
	if typeof(raw) ~= "table" or typeof(raw.levels) ~= "table" then
		return nil
	end

	local seasonStartTime = normalizeDateString(raw.seasonStartTime)
	local seasonEndTime = normalizeDateString(raw.seasonEndTime)
	local maxLevelPremiumReward = normalizeReward(raw.maxLevelPremiumReward)
	local premiumGamePassId = normalizePremiumGamePassId(raw.premiumGamePassId)
	local jumpLevelProductId = normalizePremiumGamePassId(raw.jumpLevelProductId)
	if not seasonStartTime or not seasonEndTime or not maxLevelPremiumReward or not premiumGamePassId or not jumpLevelProductId then
		return nil
	end

	local startLevel = if typeof(raw.startLevel) == "number" and raw.startLevel == raw.startLevel
		then math.max(0, math.floor(raw.startLevel))
		else 0
	local maxLevel = if typeof(raw.maxLevel) == "number" and raw.maxLevel == raw.maxLevel
		then math.max(1, math.floor(raw.maxLevel))
		else 30
	local seasonIndex = if typeof(raw.seasonIndex) == "number" and raw.seasonIndex == raw.seasonIndex
		then math.max(1, math.floor(raw.seasonIndex))
		else 1

	local levels: { [number]: BattlePassLevelDefinition } = {}
	for key, levelRaw in raw.levels do
		local levelIndex = normalizeLevel(if typeof(key) == "number" then key else tonumber(key))
		if levelIndex == nil or levelIndex > maxLevel then
			continue
		end
		local levelDef = normalizeLevelDefinition(levelRaw, levelIndex)
		if levelDef then
			levels[levelIndex] = levelDef
		end
	end

	for level = 1, maxLevel do
		if not levels[level] then
			return nil
		end
	end

	return {
		seasonIndex = seasonIndex,
		seasonStartTime = seasonStartTime,
		seasonEndTime = seasonEndTime,
		premiumGamePassId = premiumGamePassId,
		jumpLevelProductId = jumpLevelProductId,
		startLevel = startLevel,
		maxLevel = maxLevel,
		maxLevelPremiumReward = maxLevelPremiumReward,
		levels = levels,
	}
end

local function loadBattlePassDataRaw(): any?
	if RunService:IsServer() then
		local raw = DataManager.getBattlePassDataRaw()
		if raw ~= nil then
			return raw
		end
		local ok, result = pcall(function()
			return require(ServerStorage:WaitForChild("DataTable"):WaitForChild("BattlePassData"))
		end)
		if ok then
			return result
		end
		return nil
	end

	local ok, result = pcall(function()
		return require(ReplicatedStorage:WaitForChild("DataTable"):WaitForChild("BattlePassData"))
	end)
	if ok then
		return result
	end
	return nil
end

local function getRuntime(): BattlePassDataSource
	if not runtime then
		local raw = loadBattlePassDataRaw()
		local normalized = if raw ~= nil then normalizeSource(raw) else nil
		if normalized then
			runtime = normalized
			print(
				string.format(
					"[BattlePassHelper] BattlePassData 로드 (season=%d, maxLevel=%d)",
					normalized.seasonIndex,
					normalized.maxLevel
				)
			)
		else
			runtime = buildFallbackSource()
			warn("[BattlePassHelper] BattlePassData 없음/형식 오류 — fallback 사용 (src/datatable/BattlePassData.luau)")
		end
	end
	return runtime :: BattlePassDataSource
end

function BattlePassHelper.getSeasonIndex(): number
	return getRuntime().seasonIndex
end

function BattlePassHelper.getPremiumGamePassId(): number
	return getRuntime().premiumGamePassId
end

function BattlePassHelper.getJumpLevelProductId(): number
	return getRuntime().jumpLevelProductId
end

function BattlePassHelper.getSeasonStartTime(): string
	return getRuntime().seasonStartTime
end

function BattlePassHelper.getSeasonEndTime(): string
	return getRuntime().seasonEndTime
end

function BattlePassHelper.getStartLevel(): number
	return getRuntime().startLevel
end

function BattlePassHelper.getMaxLevel(): number
	return getRuntime().maxLevel
end

function BattlePassHelper.getMaxLevelPremiumReward(): Reward
	return cloneReward(getRuntime().maxLevelPremiumReward)
end

function BattlePassHelper.getLevelDefinition(level: number): BattlePassLevelDefinition?
	local levelIndex = normalizeLevel(level)
	if levelIndex == nil or levelIndex > getRuntime().maxLevel then
		return nil
	end
	local levelDef = getRuntime().levels[levelIndex]
	if not levelDef then
		return nil
	end
	return {
		level = levelDef.level,
		xpRequired = levelDef.xpRequired,
		freeReward = cloneReward(levelDef.freeReward),
		premiumReward = cloneReward(levelDef.premiumReward),
	}
end

function BattlePassHelper.getLevelIndices(): { number }
	local indices: { number } = {}
	for level = 1, getRuntime().maxLevel do
		table.insert(indices, level)
	end
	return indices
end

function BattlePassHelper.getXpRequiredForNextLevel(currentLevel: number): number?
	local maxLevel = BattlePassHelper.getMaxLevel()
	local level = math.max(0, math.floor(currentLevel))
	if level >= maxLevel then
		local maxDef = BattlePassHelper.getLevelDefinition(maxLevel)
		return if maxDef then maxDef.xpRequired else nil
	end
	local nextDef = BattlePassHelper.getLevelDefinition(level + 1)
	return if nextDef then nextDef.xpRequired else nil
end

function BattlePassHelper.buildProgressSnapshot(level: number, xp: number): BattlePassSnapshot
	local maxLevel = BattlePassHelper.getMaxLevel()
	local currentLevel = math.max(0, math.floor(level))
	local currentXp = math.max(0, math.floor(xp))
	local isMaxLevel = currentLevel >= maxLevel
	local xpRequired = BattlePassHelper.getXpRequiredForNextLevel(currentLevel) or 1
	return {
		level = currentLevel,
		xp = currentXp,
		xpRequiredForNextLevel = xpRequired,
		isMaxLevel = isMaxLevel,
		freeClaimedLevel = 0,
		premiumClaimedLevel = 0,
		maxLevelPremiumRewardClaimed = false,
		ownsPremiumPass = false,
	}
end

local function normalizeRewardTrack(raw: any): BattlePassRewardTrack?
	if raw == "free" or raw == "premium" then
		return raw
	end
	return nil
end

local function queryOwnsPremiumPass(player: Player): boolean
	local passId = BattlePassHelper.getPremiumGamePassId()
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	if not ok then
		warn("[BattlePassHelper] UserOwnsGamePassAsync 실패:", player.Name, owns)
		return false
	end
	return owns == true
end

local function grantReward(player: Player, reward: Reward): boolean
	if reward.rewardType == "Currency" then
		return DataManager.addCurrency(player, reward.currencyType, reward.amount)
	end
	if reward.rewardType == "Relic" then
		return RelicHelper.addRelicXp(player, reward.id, 1) ~= nil
	end
	if reward.rewardType == "Item" then
		return DataManager.addItem(player, reward.itemType, reward.amount)
	end
	if reward.rewardType == "Costume" then
		return DataManager.addCostume(player, reward.id)
	end
	warn("[BattlePassHelper] 미지원 보상 타입:", reward.rewardType)
	return false
end

local function resolveOwnsPremiumPass(player: Player): boolean
	local fromAttr = BattlePassHelper.getOwnsPremiumPassFromAttribute(player)
	if fromAttr ~= nil then
		return fromAttr
	end
	return queryOwnsPremiumPass(player)
end

local function buildPlayerSnapshot(player: Player): BattlePassSnapshot?
	if not DataManager.isLoaded(player) then
		return nil
	end
	local progress = DataManager.getBattlePassProgress(player)
	if not progress then
		return nil
	end
	local base = BattlePassHelper.buildProgressSnapshot(progress.level, progress.xp)
	return {
		level = base.level,
		xp = base.xp,
		xpRequiredForNextLevel = base.xpRequiredForNextLevel,
		isMaxLevel = base.isMaxLevel,
		freeClaimedLevel = progress.freeClaimedLevel,
		premiumClaimedLevel = progress.premiumClaimedLevel,
		maxLevelPremiumRewardClaimed = progress.maxLevelPremiumRewardClaimed,
		ownsPremiumPass = resolveOwnsPremiumPass(player),
	}
end

local function parseSnapshotResult(raw: any): BattlePassSnapshot?
	if typeof(raw) ~= "table" then
		return nil
	end
	if typeof(raw.level) ~= "number" or typeof(raw.xp) ~= "number" then
		return nil
	end
	local base = BattlePassHelper.buildProgressSnapshot(raw.level, raw.xp)
	return {
		level = base.level,
		xp = base.xp,
		xpRequiredForNextLevel = if typeof(raw.xpRequiredForNextLevel) == "number"
			then math.max(1, math.floor(raw.xpRequiredForNextLevel))
			else base.xpRequiredForNextLevel,
		isMaxLevel = if typeof(raw.isMaxLevel) == "boolean" then raw.isMaxLevel else base.isMaxLevel,
		freeClaimedLevel = if typeof(raw.freeClaimedLevel) == "number"
			then math.max(0, math.floor(raw.freeClaimedLevel))
			else 0,
		premiumClaimedLevel = if typeof(raw.premiumClaimedLevel) == "number"
			then math.max(0, math.floor(raw.premiumClaimedLevel))
			else 0,
		maxLevelPremiumRewardClaimed = raw.maxLevelPremiumRewardClaimed == true,
		ownsPremiumPass = raw.ownsPremiumPass == true,
	}
end

function BattlePassHelper.claimRewards(player: Player, track: BattlePassRewardTrack): BattlePassClaimResult
	local fail = { ok = false, errorMessage = "데이터 미로드", rewards = nil, snapshot = nil }
	if not RunService:IsServer() then
		return fail
	end
	if not DataManager.isLoaded(player) then
		return fail
	end

	local rewardTrack = normalizeRewardTrack(track)
	if not rewardTrack then
		return { ok = false, errorMessage = "잘못된 트랙", rewards = nil, snapshot = nil }
	end

	local progress = DataManager.getBattlePassProgress(player)
	if not progress then
		return fail
	end

	local playerLevel = math.max(0, math.floor(progress.level))
	local claimedLevel = if rewardTrack == "free" then progress.freeClaimedLevel else progress.premiumClaimedLevel
	if playerLevel <= claimedLevel then
		return { ok = false, errorMessage = "수령 가능한 보상 없음", rewards = nil, snapshot = nil }
	end

	if rewardTrack == "premium" and not resolveOwnsPremiumPass(player) then
		return { ok = false, errorMessage = "프리미엄 패스 미구매", rewards = nil, snapshot = nil }
	end

	local grantedRewards: { Reward } = {}
	for level = claimedLevel + 1, playerLevel do
		local levelDef = BattlePassHelper.getLevelDefinition(level)
		if not levelDef then
			continue
		end
		local reward = if rewardTrack == "free" then levelDef.freeReward else levelDef.premiumReward
		if not grantReward(player, reward) then
			warn("[BattlePassHelper] 보상 지급 실패:", player.Name, rewardTrack, "level", level)
			continue
		end
		table.insert(grantedRewards, cloneReward(reward))
	end

	if #grantedRewards == 0 then
		return { ok = false, errorMessage = "보상 지급 실패", rewards = nil, snapshot = nil }
	end

	local updatedProgress = DataManager.getBattlePassProgress(player)
	if not updatedProgress then
		return fail
	end
	if rewardTrack == "free" then
		updatedProgress.freeClaimedLevel = playerLevel
	else
		updatedProgress.premiumClaimedLevel = playerLevel
	end
	if not DataManager.setBattlePassProgress(player, updatedProgress) then
		return { ok = false, errorMessage = "진행 저장 실패", rewards = nil, snapshot = nil }
	end

	if not DataManager.savePlayerNow(player) then
		warn("[BattlePassHelper] 즉시 저장 실패:", player.Name, rewardTrack)
	end

	return {
		ok = true,
		errorMessage = nil,
		rewards = grantedRewards,
		snapshot = buildPlayerSnapshot(player),
	}
end

function BattlePassHelper.getSeasonStartUnix(): number?
	return TimeHelper.dateStringToUnix(getRuntime().seasonStartTime)
end

function BattlePassHelper.getSeasonEndUnix(): number?
	return TimeHelper.dateStringToDayEndUnix(getRuntime().seasonEndTime)
end

function BattlePassHelper.isSeasonActive(now: number?): boolean
	local startUnix = BattlePassHelper.getSeasonStartUnix()
	local endUnix = BattlePassHelper.getSeasonEndUnix()
	if not startUnix or not endUnix then
		return false
	end
	local ts = now or TimeHelper.now()
	return ts >= startUnix and ts <= endUnix
end

function BattlePassHelper.getSecondsUntilSeasonEnd(now: number?): number
	local endUnix = BattlePassHelper.getSeasonEndUnix()
	if not endUnix then
		return 0
	end
	local ts = now or TimeHelper.now()
	return math.max(0, endUnix - ts)
end

function BattlePassHelper.canClaimMaxLevelPremiumReward(
	level: number,
	ownsPremiumPass: boolean,
	alreadyClaimed: boolean
): boolean
	if alreadyClaimed then
		return false
	end
	if not ownsPremiumPass then
		return false
	end
	local currentLevel = if typeof(level) == "number" and level == level then math.floor(level) else 0
	return currentLevel >= BattlePassHelper.getMaxLevel()
end

function BattlePassHelper.hasClaimableRewards(snapshot: BattlePassSnapshot): boolean
	if snapshot.level > snapshot.freeClaimedLevel then
		return true
	end
	if snapshot.ownsPremiumPass and snapshot.level > snapshot.premiumClaimedLevel then
		return true
	end
	return BattlePassHelper.canClaimMaxLevelPremiumReward(
		snapshot.level,
		snapshot.ownsPremiumPass,
		snapshot.maxLevelPremiumRewardClaimed
	)
end

local function syncPremiumPassState(player: Player): boolean
	local owns = queryOwnsPremiumPass(player)
	player:SetAttribute(ATTR_OWNS_PREMIUM, owns)
	return owns
end

local function ensureGetSnapshotRemote(): RemoteFunction
	if getSnapshotRemote then
		return getSnapshotRemote
	end

	local existing = ReplicatedStorage:FindFirstChild(GET_SNAPSHOT_REMOTE_NAME)
	local remote = if existing and existing:IsA("RemoteFunction")
		then existing
		else Instance.new("RemoteFunction")
	remote.Name = GET_SNAPSHOT_REMOTE_NAME
	remote.Parent = ReplicatedStorage
	getSnapshotRemote = remote
	return remote
end

local function getSnapshotRemoteOnClient(): RemoteFunction
	local remote = ReplicatedStorage:FindFirstChild(GET_SNAPSHOT_REMOTE_NAME)
	if not remote then
		remote = ReplicatedStorage:WaitForChild(GET_SNAPSHOT_REMOTE_NAME, 10)
	end
	assert(remote and remote:IsA("RemoteFunction"), "[BattlePassHelper] GetBattlePassSnapshot RemoteFunction 없음")
	return remote :: RemoteFunction
end

function BattlePassHelper.fetchSnapshot(player: Player?): BattlePassSnapshot?
	if RunService:IsServer() then
		local target = player or Players.LocalPlayer
		if not target then
			return nil
		end
		if not DataManager.waitUntilLoaded(target) then
			return nil
		end
		return buildPlayerSnapshot(target)
	end

	local ok, result = pcall(function()
		return getSnapshotRemoteOnClient():InvokeServer()
	end)
	if not ok then
		warn("[BattlePassHelper] GetBattlePassSnapshot 실패:", result)
		return nil
	end
	if typeof(result) ~= "table" then
		warn("[BattlePassHelper] GetBattlePassSnapshot 응답 형식 오류:", result)
		return nil
	end
	if typeof(result.level) ~= "number" or typeof(result.xp) ~= "number" then
		warn("[BattlePassHelper] GetBattlePassSnapshot 필드 누락:", result)
		return nil
	end
	return parseSnapshotResult(result)
end

local function parseClaimResult(raw: any): BattlePassClaimResult?
	if typeof(raw) ~= "table" or typeof(raw.ok) ~= "boolean" then
		return nil
	end
	local rewards: { Reward }? = nil
	if typeof(raw.rewards) == "table" then
		rewards = {}
		for _, rewardRaw in raw.rewards do
			local reward = normalizeReward(rewardRaw)
			if reward then
				table.insert(rewards :: { Reward }, reward)
			end
		end
	end
	return {
		ok = raw.ok,
		errorMessage = if typeof(raw.errorMessage) == "string" then raw.errorMessage else nil,
		rewards = rewards,
		snapshot = if raw.snapshot ~= nil then parseSnapshotResult(raw.snapshot) else nil,
	}
end

local function ensureClaimRewardsRemote(): RemoteFunction
	if claimRewardsRemote then
		return claimRewardsRemote
	end

	local existing = ReplicatedStorage:FindFirstChild(CLAIM_REWARDS_REMOTE_NAME)
	local remote = if existing and existing:IsA("RemoteFunction")
		then existing
		else Instance.new("RemoteFunction")
	remote.Name = CLAIM_REWARDS_REMOTE_NAME
	remote.Parent = ReplicatedStorage
	claimRewardsRemote = remote
	return remote
end

local function getClaimRewardsRemoteOnClient(): RemoteFunction
	local remote = ReplicatedStorage:FindFirstChild(CLAIM_REWARDS_REMOTE_NAME)
	if not remote then
		remote = ReplicatedStorage:WaitForChild(CLAIM_REWARDS_REMOTE_NAME, 10)
	end
	assert(remote and remote:IsA("RemoteFunction"), "[BattlePassHelper] ClaimBattlePassRewards RemoteFunction 없음")
	return remote :: RemoteFunction
end

function BattlePassHelper.requestClaimRewards(track: BattlePassRewardTrack): BattlePassClaimResult?
	if RunService:IsServer() then
		local player = Players.LocalPlayer
		if not player then
			return nil
		end
		return BattlePassHelper.claimRewards(player, track)
	end

	local ok, result = pcall(function()
		return getClaimRewardsRemoteOnClient():InvokeServer(track)
	end)
	if not ok then
		warn("[BattlePassHelper] ClaimBattlePassRewards 실패:", result)
		return nil
	end
	return parseClaimResult(result)
end

local function ensureGetStateRemote(): RemoteFunction
	if getStateRemote then
		return getStateRemote
	end

	local existing = ReplicatedStorage:FindFirstChild(GET_STATE_REMOTE_NAME)
	local remote = if existing and existing:IsA("RemoteFunction")
		then existing
		else Instance.new("RemoteFunction")
	remote.Name = GET_STATE_REMOTE_NAME
	remote.Parent = ReplicatedStorage
	getStateRemote = remote
	return remote
end

local function getStateRemoteOnClient(): RemoteFunction
	local remote = ReplicatedStorage:FindFirstChild(GET_STATE_REMOTE_NAME)
	if not remote then
		remote = ReplicatedStorage:WaitForChild(GET_STATE_REMOTE_NAME, 10)
	end
	assert(remote and remote:IsA("RemoteFunction"), "[BattlePassHelper] GetBattlePassPremiumState RemoteFunction 없음")
	return remote :: RemoteFunction
end

function BattlePassHelper.getOwnsPremiumPassFromAttribute(player: Player?): boolean?
	local target = player or Players.LocalPlayer
	if not target then
		return nil
	end
	local raw = target:GetAttribute(ATTR_OWNS_PREMIUM)
	if typeof(raw) == "boolean" then
		return raw
	end
	return nil
end

function BattlePassHelper.fetchOwnsPremiumPass(player: Player?): boolean
	if RunService:IsServer() then
		local target = player or Players.LocalPlayer
		if not target then
			return false
		end
		return syncPremiumPassState(target)
	end

	local ok, result = pcall(function()
		return getStateRemoteOnClient():InvokeServer()
	end)
	if not ok then
		warn("[BattlePassHelper] GetBattlePassPremiumState 실패:", result)
		local fromAttr = BattlePassHelper.getOwnsPremiumPassFromAttribute()
		return fromAttr == true
	end
	if typeof(result) == "boolean" then
		return result
	end
	warn("[BattlePassHelper] GetBattlePassPremiumState 응답 형식 오류:", result)
	local fromAttr = BattlePassHelper.getOwnsPremiumPassFromAttribute()
	return fromAttr == true
end

local function onPlayerAdded(player: Player)
	task.spawn(function()
		syncPremiumPassState(player)
	end)
end

function BattlePassHelper.init()
	if initialized then
		return
	end
	initialized = true

	getRuntime()

	if not RunService:IsServer() then
		return
	end

	local remote = ensureGetStateRemote()
	remote.OnServerInvoke = function(player: Player)
		return syncPremiumPassState(player)
	end

	local snapshotRemote = ensureGetSnapshotRemote()
	snapshotRemote.OnServerInvoke = function(player: Player)
		if not DataManager.waitUntilLoaded(player) then
			return nil
		end
		return buildPlayerSnapshot(player)
	end

	local claimRemote = ensureClaimRewardsRemote()
	claimRemote.OnServerInvoke = function(player: Player, track: any)
		if not DataManager.waitUntilLoaded(player) then
			return { ok = false, errorMessage = "데이터 미로드", rewards = nil, snapshot = nil }
		end
		return BattlePassHelper.claimRewards(player, track)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	print("[BattlePassHelper] 초기화 완료")
end

return BattlePassHelper
