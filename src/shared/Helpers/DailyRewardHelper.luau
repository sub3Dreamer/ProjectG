--[[
	7일 출석 보상 런타임 (shared)

	마스터 데이터: DataManager.getDailyRewardDataRaw() (서버) / ReplicatedStorage.DataTable.DailyRewardData (클라이언트)
	유저 진행도: DataManager.SavedPlayerData.DailyReward[datasetIndex]
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local DataManager = require(Shared.Managers.DataManager)
local AchievementHelper = require(Shared.Helpers.AchievementHelper)
local TimeHelper = require(Shared.Helpers.TimeHelper)

local DailyRewardHelper = {}

export type CurrencyType = Types.CurrencyType
export type DailyRewardEntry = Types.DailyRewardEntry
export type DailyRewardDataset = Types.DailyRewardDataset
export type DailyRewardDataSource = Types.DailyRewardDataSource
export type DailyRewardDatasetProgress = Types.DailyRewardDatasetProgress

local REWARD_DAYS = 7
local DEFAULT_ACTIVE_INDEX = 0
local GET_SNAPSHOT_REMOTE_NAME = "GetDailyRewardSnapshot"
local CLAIM_REMOTE_NAME = "ClaimDailyRewards"

local initialized = false
local runtime: DailyRewardDataSource? = nil
local attendanceProcessed: { [number]: boolean } = {}

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

local function gemReward(amount: number): DailyRewardEntry
	return { currencyType = "Gem", amount = amount }
end

local function buildFallbackSource(): DailyRewardDataSource
	return {
		activeDatasetIndex = DEFAULT_ACTIVE_INDEX,
		datasets = {
			[DEFAULT_ACTIVE_INDEX] = {
				index = DEFAULT_ACTIVE_INDEX,
				name = "Default",
				rewards = {
					gemReward(10),
					gemReward(20),
					gemReward(30),
					gemReward(40),
					gemReward(50),
					gemReward(60),
					gemReward(100),
				},
			},
		},
	}
end

local function normalizeRewardEntry(raw: any): DailyRewardEntry?
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

local function normalizeRewards(raw: any): { DailyRewardEntry }?
	if typeof(raw) ~= "table" or #raw ~= REWARD_DAYS then
		return nil
	end
	local rewards: { DailyRewardEntry } = {}
	for day = 1, REWARD_DAYS do
		local entry = normalizeRewardEntry(raw[day])
		if not entry then
			return nil
		end
		rewards[day] = entry
	end
	return rewards
end

local function normalizeDataset(raw: any, expectedIndex: number?): DailyRewardDataset?
	if typeof(raw) ~= "table" then
		return nil
	end
	local index = if typeof(raw.index) == "number" then math.floor(raw.index) else expectedIndex
	if index == nil then
		return nil
	end
	local name = if typeof(raw.name) == "string" and raw.name ~= "" then raw.name else ("Dataset_" .. tostring(index))
	local rewards = normalizeRewards(raw.rewards)
	if not rewards then
		return nil
	end
	return {
		index = index,
		name = name,
		rewards = rewards,
	}
end

local function normalizeSource(raw: any): DailyRewardDataSource?
	if typeof(raw) ~= "table" or typeof(raw.datasets) ~= "table" then
		return nil
	end

	local datasets: { [number]: DailyRewardDataset } = {}
	for key, datasetRaw in raw.datasets do
		local datasetIndex = if typeof(key) == "number" then math.floor(key) else tonumber(key)
		if datasetIndex == nil then
			continue
		end
		local dataset = normalizeDataset(datasetRaw, datasetIndex)
		if dataset then
			datasets[datasetIndex] = dataset
		end
	end

	if not datasets[DEFAULT_ACTIVE_INDEX] then
		return nil
	end

	local activeIndex = DEFAULT_ACTIVE_INDEX
	if typeof(raw.activeDatasetIndex) == "number" and raw.activeDatasetIndex == raw.activeDatasetIndex then
		activeIndex = math.floor(raw.activeDatasetIndex)
	end
	if not datasets[activeIndex] then
		activeIndex = DEFAULT_ACTIVE_INDEX
	end

	return {
		activeDatasetIndex = activeIndex,
		datasets = datasets,
	}
end

local function loadDailyRewardDataRaw(): any?
	if RunService:IsServer() then
		local raw = DataManager.getDailyRewardDataRaw()
		if raw ~= nil then
			return raw
		end
		local ok, result = pcall(function()
			return require(ServerStorage:WaitForChild("DataTable"):WaitForChild("DailyRewardData"))
		end)
		if ok then
			return result
		end
		return nil
	end

	local ok, result = pcall(function()
		return require(ReplicatedStorage:WaitForChild("DataTable"):WaitForChild("DailyRewardData"))
	end)
	if ok then
		return result
	end
	return nil
end

local function getRuntime(): DailyRewardDataSource
	if not runtime then
		local raw = loadDailyRewardDataRaw()
		local normalized = if raw ~= nil then normalizeSource(raw) else nil
		if normalized then
			runtime = normalized
			print(
				string.format(
					"[DailyRewardHelper] DailyRewardData 로드 (activeIndex=%d)",
					normalized.activeDatasetIndex
				)
			)
		else
			runtime = buildFallbackSource()
			warn(
				"[DailyRewardHelper] DailyRewardData 없음/형식 오류 — index 0 fallback (src/datatable/DailyRewardData.luau)"
			)
		end
	end
	return runtime :: DailyRewardDataSource
end

function DailyRewardHelper.getActiveDatasetIndex(): number
	return getRuntime().activeDatasetIndex
end

function DailyRewardHelper.getDataset(datasetIndex: number): DailyRewardDataset?
	return getRuntime().datasets[datasetIndex]
end

function DailyRewardHelper.getActiveDataset(): DailyRewardDataset?
	return DailyRewardHelper.getDataset(DailyRewardHelper.getActiveDatasetIndex())
end

function DailyRewardHelper.getReward(datasetIndex: number, day: number): DailyRewardEntry?
	if day < 1 or day > REWARD_DAYS then
		return nil
	end
	local dataset = DailyRewardHelper.getDataset(datasetIndex)
	if not dataset then
		return nil
	end
	return dataset.rewards[day]
end

function DailyRewardHelper.getActiveReward(day: number): DailyRewardEntry?
	return DailyRewardHelper.getReward(DailyRewardHelper.getActiveDatasetIndex(), day)
end

function DailyRewardHelper.getAllDatasets(): { [number]: DailyRewardDataset }
	return getRuntime().datasets
end

function DailyRewardHelper.getUtcDateString(): string
	return TimeHelper.unixToDateString(TimeHelper.now())
end

local function newEmptyClaimedDays(): { boolean }
	local claimedDays: { boolean } = {}
	for day = 1, REWARD_DAYS do
		claimedDays[day] = false
	end
	return claimedDays
end

local function cloneClaimedDays(claimedDays: { boolean }): { boolean }
	local out: { boolean } = {}
	for day = 1, REWARD_DAYS do
		out[day] = claimedDays[day] == true
	end
	return out
end

local function buildClaimedDaysForSnapshot(claimedDays: { boolean }): { boolean }
	return cloneClaimedDays(claimedDays)
end

function DailyRewardHelper.hasClaimableRewards(player: Player, datasetIndex: number?): boolean
	local index = datasetIndex or DailyRewardHelper.getActiveDatasetIndex()
	local entry = DataManager.getDailyRewardEntry(player, index)
	if not entry then
		return false
	end
	for day = 1, entry.currentDay do
		if not entry.claimedDays[day] then
			return true
		end
	end
	return false
end

function DailyRewardHelper.processLobbyAttendance(player: Player): boolean
	if not DataManager.isLoaded(player) then
		return false
	end

	local datasetIndex = DailyRewardHelper.getActiveDatasetIndex()
	local now = TimeHelper.now()
	local entry = DataManager.getDailyRewardEntry(player, datasetIndex)

	if not entry then
		local newEntry: DailyRewardDatasetProgress = {
			currentDay = 1,
			claimedDays = newEmptyClaimedDays(),
			lastAttendanceTime = now,
		}
	DataManager.setDailyRewardEntry(player, datasetIndex, newEntry)
	print(string.format("[DailyRewardHelper] 첫 출석: %s Day=1 dataset=%d", player.Name, datasetIndex))
	AchievementHelper.incrementByType(player, "Attendance")
	return true
	end

	if TimeHelper.isSameUtcDay(entry.lastAttendanceTime, now) then
		return false
	end

	local nextEntry: DailyRewardDatasetProgress = {
		currentDay = entry.currentDay,
		claimedDays = cloneClaimedDays(entry.claimedDays),
		lastAttendanceTime = now,
	}

	if entry.currentDay == REWARD_DAYS then
		nextEntry.currentDay = 1
		nextEntry.claimedDays = newEmptyClaimedDays()
		print(
			string.format(
				"[DailyRewardHelper] 사이클 리셋: %s Day=1 dataset=%d (미수령 소멸)",
				player.Name,
				datasetIndex
			)
		)
	else
		nextEntry.currentDay = entry.currentDay + 1
		print(
			string.format(
				"[DailyRewardHelper] 출석: %s Day=%d dataset=%d",
				player.Name,
				nextEntry.currentDay,
				datasetIndex
			)
		)
	end

	DataManager.setDailyRewardEntry(player, datasetIndex, nextEntry)
	AchievementHelper.incrementByType(player, "Attendance")
	return true
end

local function normalizeClaimDaysRequest(raw: any): { number }?
	if typeof(raw) ~= "table" then
		return nil
	end
	local days: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, value in raw do
		if typeof(value) == "number" and value == value then
			local day = math.floor(value)
			if day >= 1 and day <= REWARD_DAYS and not seen[day] then
				seen[day] = true
				table.insert(days, day)
			end
		end
	end
	table.sort(days)
	if #days == 0 then
		return nil
	end
	return days
end

function DailyRewardHelper.claimRewards(player: Player, days: { number }): {
	ok: boolean,
	claimedDays: { number },
	errorMessage: string?,
}
	local empty = { ok = false, claimedDays = {}, errorMessage = "데이터 미로드" }
	if not DataManager.isLoaded(player) then
		return empty
	end

	local datasetIndex = DailyRewardHelper.getActiveDatasetIndex()
	local entry = DataManager.getDailyRewardEntry(player, datasetIndex)
	if not entry then
		return { ok = false, claimedDays = {}, errorMessage = "출석 기록 없음" }
	end

	local claimed: { number } = {}
	for _, day in ipairs(days) do
		if day < 1 or day > REWARD_DAYS then
			continue
		end
		if day > entry.currentDay then
			continue
		end
		if entry.claimedDays[day] then
			continue
		end

		local reward = DailyRewardHelper.getReward(datasetIndex, day)
		if not reward then
			continue
		end

		local granted = DataManager.addCurrency(player, reward.currencyType, reward.amount)
		if not granted then
			warn("[DailyRewardHelper] 재화 지급 실패:", player.Name, "day", day)
			continue
		end

		entry.claimedDays[day] = true
		table.insert(claimed, day)
	end

	if #claimed == 0 then
		return { ok = false, claimedDays = {}, errorMessage = "수령 가능한 보상 없음" }
	end

	if not DataManager.setDailyRewardEntry(player, datasetIndex, entry) then
		return { ok = false, claimedDays = {}, errorMessage = "진행 저장 실패" }
	end

	if not DataManager.savePlayerNow(player) then
		warn("[DailyRewardHelper] 즉시 저장 실패:", player.Name)
	end

	return { ok = true, claimedDays = claimed, errorMessage = nil }
end

local function buildPlayerSnapshot(player: Player): {
	activeDatasetIndex: number,
	rewards: { { currencyType: string, amount: number } },
	currentDay: number,
	claimedDays: { boolean },
	hasClaimable: boolean,
}?
	local datasetIndex = DailyRewardHelper.getActiveDatasetIndex()
	local dataset = DailyRewardHelper.getDataset(datasetIndex)
	if not dataset then
		return nil
	end

	local rewards: { { currencyType: string, amount: number } } = {}
	for day = 1, REWARD_DAYS do
		local rewardEntry = dataset.rewards[day]
		rewards[day] = {
			currencyType = rewardEntry.currencyType,
			amount = rewardEntry.amount,
		}
	end

	local progress = DataManager.getDailyRewardEntry(player, datasetIndex)
	local currentDay = if progress then progress.currentDay else 0
	local claimedDays = if progress then buildClaimedDaysForSnapshot(progress.claimedDays) else newEmptyClaimedDays()
	local hasClaimable = DailyRewardHelper.hasClaimableRewards(player, datasetIndex)

	return {
		activeDatasetIndex = datasetIndex,
		rewards = rewards,
		currentDay = currentDay,
		claimedDays = claimedDays,
		hasClaimable = hasClaimable,
	}
end

local function ensureAttendanceProcessed(player: Player)
	local userId = player.UserId
	if attendanceProcessed[userId] then
		return
	end
	DailyRewardHelper.processLobbyAttendance(player)
	attendanceProcessed[userId] = true
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
		ensureAttendanceProcessed(player)
		return buildPlayerSnapshot(player)
	end

	local claimExisting = ReplicatedStorage:FindFirstChild(CLAIM_REMOTE_NAME)
	local claimRemote = if claimExisting and claimExisting:IsA("RemoteFunction")
		then claimExisting
		else Instance.new("RemoteFunction")
	claimRemote.Name = CLAIM_REMOTE_NAME
	claimRemote.Parent = ReplicatedStorage
	claimRemote.OnServerInvoke = function(player: Player, daysRaw: any)
		if not DataManager.waitUntilLoaded(player) then
			return { ok = false, claimedDays = {}, errorMessage = "데이터 미로드" }
		end
		ensureAttendanceProcessed(player)
		local days = normalizeClaimDaysRequest(daysRaw)
		if not days then
			return { ok = false, claimedDays = {}, errorMessage = "잘못된 요청" }
		end
		return DailyRewardHelper.claimRewards(player, days)
	end
end

local function onPlayerAdded(player: Player)
	task.spawn(function()
		if not DataManager.waitUntilLoaded(player) then
			return
		end
		if not player.Parent then
			return
		end
		ensureAttendanceProcessed(player)
	end)
end

local function onPlayerRemoving(player: Player)
	attendanceProcessed[player.UserId] = nil
end

function DailyRewardHelper.init()
	if initialized then
		return
	end
	initialized = true

	getRuntime()

	bindRemotes()

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	print("[DailyRewardHelper] 초기화 완료")
end

return DailyRewardHelper
