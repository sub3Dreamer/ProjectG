--[[
	MissionHelper (shared)

	마스터 데이터: DataManager.getMissionDataRaw() (서버) / ReplicatedStorage.DataTable.MissionData (클라이언트)
	일일 미션 갱신: UTC 00:00 (= KST 09:00) — MissionHelper.DailyResetUtcHour
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DataManager = require(Shared.Managers.DataManager)
local AchievementHelper = require(Shared.Helpers.AchievementHelper)
local TimeHelper = require(Shared.Helpers.TimeHelper)
local Types = require(Shared.Types)

local MissionHelper = {}

export type CurrencyType = Types.CurrencyType
export type MissionRewardEntry = Types.MissionRewardEntry
export type MissionDefinition = Types.MissionDefinition
export type MissionDataSource = Types.MissionDataSource

-- UTC 00:00 = KST 09:00 일일 미션 갱신 시각 (TimeHelper.DailyResetUtcHour 와 동기화)
MissionHelper.DailyResetUtcHour = TimeHelper.DailyResetUtcHour

local GET_SNAPSHOT_REMOTE_NAME = "GetMissionSnapshot"
local CLAIM_REMOTE_NAME = "ClaimMissionReward"

local initialized = false
local runtime: MissionDataSource? = nil

local function normalizeMissionIndex(raw: any): number?
	if typeof(raw) ~= "number" or raw ~= raw then
		return nil
	end
	local index = math.floor(raw)
	if index < 1 then
		return nil
	end
	return index
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

local function normalizeRewardEntry(raw: any): MissionRewardEntry?
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

local function normalizeRewards(raw: any): { MissionRewardEntry }?
	if typeof(raw) ~= "table" then
		return nil
	end
	local rewards: { MissionRewardEntry } = {}
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

local function cloneRewards(rewards: { MissionRewardEntry }): { MissionRewardEntry }
	local out: { MissionRewardEntry } = {}
	for _, reward in rewards do
		table.insert(out, {
			currencyType = reward.currencyType,
			amount = reward.amount,
		})
	end
	return out
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

local function normalizeMissionDefinition(raw: any, tableKeyIndex: number?): MissionDefinition?
	if typeof(raw) ~= "table" then
		return nil
	end
	local indexFromRow = normalizeMissionIndex(raw.index)
	local index = tableKeyIndex or indexFromRow
	if index == nil then
		return nil
	end
	if indexFromRow ~= nil and indexFromRow ~= index then
		warn(string.format("[MissionHelper] MissionData index 불일치 (key=%d, row.index=%d) — key 사용", index, indexFromRow))
	end
	local stringKey = if typeof(raw.stringKey) == "string" and raw.stringKey ~= ""
		then raw.stringKey
		else string.format("Mission_%02d", index)
	local progressCnt = normalizeProgressCount(raw.progressCnt)
	local rewards = normalizeRewards(raw.rewards)
	if not progressCnt or not rewards then
		return nil
	end
	return {
		index = index,
		stringKey = stringKey,
		progressCnt = progressCnt,
		rewards = rewards,
	}
end

local function buildFallbackSource(): MissionDataSource
	return {
		missions = {
			[1] = {
				index = 1,
				stringKey = "Mission_01",
				progressCnt = 1,
				rewards = {
					{ currencyType = "Gold", amount = 1000 },
				},
			},
		},
	}
end

local function normalizeSource(raw: any): MissionDataSource?
	if typeof(raw) ~= "table" or typeof(raw.missions) ~= "table" then
		return nil
	end

	local missions: { [number]: MissionDefinition } = {}
	for key, missionRaw in raw.missions do
		local missionIndex = normalizeMissionIndex(if typeof(key) == "number" then key else tonumber(key))
		if missionIndex == nil then
			continue
		end
		local mission = normalizeMissionDefinition(missionRaw, missionIndex)
		if mission then
			missions[missionIndex] = mission
		end
	end

	if next(missions) == nil then
		return nil
	end

	return { missions = missions }
end

local function loadMissionDataRaw(): any?
	if RunService:IsServer() then
		local raw = DataManager.getMissionDataRaw()
		if raw ~= nil then
			return raw
		end
		local ok, result = pcall(function()
			return require(ServerStorage:WaitForChild("DataTable"):WaitForChild("MissionData"))
		end)
		if ok then
			return result
		end
		return nil
	end

	local ok, result = pcall(function()
		return require(ReplicatedStorage:WaitForChild("DataTable"):WaitForChild("MissionData"))
	end)
	if ok then
		return result
	end
	return nil
end

local function getRuntime(): MissionDataSource
	if not runtime then
		local raw = loadMissionDataRaw()
		local normalized = if raw ~= nil then normalizeSource(raw) else nil
		if normalized then
			runtime = normalized
			print(string.format("[MissionHelper] MissionData 로드 (%d개)", MissionHelper.getMissionCount()))
		else
			runtime = buildFallbackSource()
			warn("[MissionHelper] MissionData 없음/형식 오류 — fallback 사용 (src/datatable/MissionData.luau)")
		end
	end
	return runtime :: MissionDataSource
end

function MissionHelper.getDailyResetUtcHour(): number
	return MissionHelper.DailyResetUtcHour
end

function MissionHelper.getSecondsUntilDailyReset(): number
	return TimeHelper.getSecondsUntilDailyReset()
end

function MissionHelper.getMissionDayStartTime(): number
	return TimeHelper.getUtcDayStartTime()
end

function MissionHelper.getMission(index: number): MissionDefinition?
	local missionIndex = normalizeMissionIndex(index)
	if missionIndex == nil then
		return nil
	end
	local mission = getRuntime().missions[missionIndex]
	if not mission then
		return nil
	end
	return {
		index = mission.index,
		stringKey = mission.stringKey,
		progressCnt = mission.progressCnt,
		rewards = cloneRewards(mission.rewards),
	}
end

function MissionHelper.getAllMissions(): { [number]: MissionDefinition }
	local out: { [number]: MissionDefinition } = {}
	for index, mission in getRuntime().missions do
		out[index] = {
			index = mission.index,
			stringKey = mission.stringKey,
			progressCnt = mission.progressCnt,
			rewards = cloneRewards(mission.rewards),
		}
	end
	return out
end

function MissionHelper.getMissionIndices(): { number }
	local indices: { number } = {}
	for index in getRuntime().missions do
		table.insert(indices, index)
	end
	table.sort(indices)
	return indices
end

function MissionHelper.getMissionCount(): number
	local count = 0
	for _ in getRuntime().missions do
		count += 1
	end
	return count
end

local MISSIONS_PER_DAY = 3

local function pickRandomMissionIndices(count: number): { number }
	local pool = table.clone(MissionHelper.getMissionIndices())
	local n = #pool
	for i = n, 2, -1 do
		local j = math.random(i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	local picked: { number } = {}
	for i = 1, math.min(count, n) do
		table.insert(picked, pool[i])
	end
	table.sort(picked)
	return picked
end

local function isMissionSelectedToday(state: Types.MissionProgress, missionIndex: number): boolean
	for _, idx in state.selectedIndices do
		if idx == missionIndex then
			return true
		end
	end
	return false
end

local function newEmptyMissionProgress(missionDayStartTime: number): Types.MissionProgress
	return {
		missionDayStartTime = missionDayStartTime,
		selectedIndices = pickRandomMissionIndices(MISSIONS_PER_DAY),
		progress = {},
		claimed = {},
	}
end

local function ensureMissionDay(player: Player): Types.MissionProgress?
	if not DataManager.isLoaded(player) then
		return nil
	end

	local todayStart = MissionHelper.getMissionDayStartTime()
	local current = DataManager.getMissionProgress(player)
	local needsFresh = not current
		or current.missionDayStartTime ~= todayStart
		or typeof(current.selectedIndices) ~= "table"
		or #current.selectedIndices == 0
	if needsFresh then
		local fresh = newEmptyMissionProgress(todayStart)
		DataManager.setMissionProgress(player, fresh)
		return fresh
	end
	return current
end

function MissionHelper.incrementProgress(player: Player, missionIndex: number, amount: number?): boolean
	if not RunService:IsServer() then
		return false
	end
	if not DataManager.isLoaded(player) then
		return false
	end

	local index = normalizeMissionIndex(missionIndex)
	if index == nil then
		return false
	end

	local mission = MissionHelper.getMission(index)
	if not mission then
		return false
	end

	local state = ensureMissionDay(player)
	if not state then
		return false
	end
	if not isMissionSelectedToday(state, index) then
		return false
	end
	if state.claimed[index] == true then
		return false
	end

	local current = state.progress[index] or 0
	local total = mission.progressCnt
	if current >= total then
		return false
	end

	local delta = if typeof(amount) == "number" and amount == amount then math.max(1, math.floor(amount)) else 1
	local nextCount = math.min(current + delta, total)
	state.progress[index] = nextCount
	local saved = DataManager.setMissionProgress(player, state)
	if saved then
		print(
			string.format(
				"[MissionHelper] 미션 %d 카운팅 (%s): current=%d total=%d",
				index,
				player.Name,
				nextCount,
				total
			)
		)
	end
	return saved
end

function MissionHelper.hasClaimableRewards(player: Player): boolean
	if not DataManager.isLoaded(player) then
		return false
	end
	local state = ensureMissionDay(player)
	if not state then
		return false
	end
	for _, index in state.selectedIndices do
		local mission = MissionHelper.getMission(index)
		if mission and state.claimed[index] ~= true then
			local current = state.progress[index] or 0
			if current >= mission.progressCnt then
				return true
			end
		end
	end
	return false
end

function MissionHelper.claimReward(player: Player, missionIndex: number): {
	ok: boolean,
	errorMessage: string?,
	rewards: { MissionRewardEntry }?,
}
	local fail = { ok = false, errorMessage = "데이터 미로드", rewards = nil }
	if not RunService:IsServer() then
		return fail
	end
	if not DataManager.isLoaded(player) then
		return fail
	end

	local index = normalizeMissionIndex(missionIndex)
	if index == nil then
		return { ok = false, errorMessage = "잘못된 미션", rewards = nil }
	end

	local mission = MissionHelper.getMission(index)
	if not mission then
		return { ok = false, errorMessage = "미션 없음", rewards = nil }
	end

	local state = ensureMissionDay(player)
	if not state then
		return fail
	end
	if not isMissionSelectedToday(state, index) then
		return { ok = false, errorMessage = "미션 없음", rewards = nil }
	end
	if state.claimed[index] == true then
		return { ok = false, errorMessage = "이미 수령함", rewards = nil }
	end

	local current = state.progress[index] or 0
	if current < mission.progressCnt then
		return { ok = false, errorMessage = "미션 미완료", rewards = nil }
	end

	state.claimed[index] = true
	if not DataManager.setMissionProgress(player, state) then
		state.claimed[index] = nil
		return { ok = false, errorMessage = "진행 저장 실패", rewards = nil }
	end

	local grantedRewards: { MissionRewardEntry } = {}
	for _, reward in mission.rewards do
		local granted = DataManager.addCurrency(player, reward.currencyType, reward.amount)
		if not granted then
			warn("[MissionHelper] 재화 지급 실패:", player.Name, "mission", index, reward.currencyType)
			continue
		end
		table.insert(grantedRewards, {
			currencyType = reward.currencyType,
			amount = reward.amount,
		})
	end

	if #grantedRewards == 0 then
		state.claimed[index] = nil
		DataManager.setMissionProgress(player, state)
		return { ok = false, errorMessage = "보상 지급 실패", rewards = nil }
	end

	if not DataManager.savePlayerNow(player) then
		warn("[MissionHelper] 즉시 저장 실패:", player.Name, "mission", index)
	end

	AchievementHelper.incrementByType(player, "MissionClear")
	return { ok = true, errorMessage = nil, rewards = grantedRewards }
end

local function buildPlayerSnapshot(player: Player): {
	selectedIndices: { number },
	progress: { [number]: number },
	claimed: { [number]: boolean },
	hasClaimable: boolean,
}?
	local state = ensureMissionDay(player)
	if not state then
		return nil
	end

	local progress: { [number]: number } = {}
	local claimed: { [number]: boolean } = {}
	for _, index in state.selectedIndices do
		progress[index] = state.progress[index] or 0
		claimed[index] = state.claimed[index] == true
	end

	return {
		selectedIndices = state.selectedIndices,
		progress = progress,
		claimed = claimed,
		hasClaimable = MissionHelper.hasClaimableRewards(player),
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
	claimRemote.OnServerInvoke = function(player: Player, missionIndexRaw: any)
		if not DataManager.waitUntilLoaded(player) then
			return { ok = false, errorMessage = "데이터 미로드", rewards = nil }
		end
		local missionIndex = normalizeMissionIndex(missionIndexRaw)
		if missionIndex == nil then
			return { ok = false, errorMessage = "잘못된 요청", rewards = nil }
		end
		return MissionHelper.claimReward(player, missionIndex)
	end
end

function MissionHelper.init()
	if initialized then
		return
	end
	initialized = true

	getRuntime()

	if RunService:IsServer() then
		bindRemotes()
	end

	print(
		string.format(
			"[MissionHelper] 초기화 완료 (일일 갱신 UTC %02d:00 = KST %02d:00)",
			MissionHelper.DailyResetUtcHour,
			(MissionHelper.DailyResetUtcHour + 9) % 24
		)
	)
end

return MissionHelper
