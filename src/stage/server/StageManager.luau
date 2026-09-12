local StageManager = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlaceManager = require(Shared.Managers.PlaceManager)
local GameManager = require(Shared.Managers.GameManager)
local DataManager = require(Shared.Managers.DataManager)
local MissionHelper = require(Shared.Helpers.MissionHelper)
local AchievementHelper = require(Shared.Helpers.AchievementHelper)
local StageHelper = require(Shared.Helpers.StageHelper)
local FeverGaugeHandler = require(script.Parent.FeverGaugeHandler)
local XpHandler = require(script.Parent.XpHandler)
local Types = require(Shared.Types)

StageManager.CurrentStage = nil :: number?
StageManager.CurrentSession = nil
StageManager.StageStartedAt = nil :: number?

export type StageSession = {
	stageNumber: number,
	difficulty: number,
	roomId: string,
	capacity: number,
	source: "teleport" | "studio",
}

local function parseStageSession(raw: any): StageSession?
	if typeof(raw) ~= "table" then
		return nil
	end

	local stageNumber = tonumber(raw.stageNumber)
	local difficulty = tonumber(raw.difficulty)
	local capacity = tonumber(raw.capacity)
	local roomIdRaw = raw.roomId
	if not stageNumber or stageNumber < 1 then
		return nil
	end
	if not difficulty or difficulty < 1 or difficulty > 3 then
		return nil
	end
	if not capacity or capacity < 1 then
		return nil
	end
	if typeof(roomIdRaw) ~= "string" and typeof(roomIdRaw) ~= "number" then
		return nil
	end

	return {
		stageNumber = math.floor(stageNumber),
		difficulty = math.floor(difficulty),
		roomId = tostring(roomIdRaw),
		capacity = math.floor(capacity),
		source = "teleport",
	}
end

local function tryCacheSessionFromPlayer(player: Player): StageSession?
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not ok or typeof(joinData) ~= "table" then
		return nil
	end

	local session = parseStageSession(joinData.TeleportData)
	if session then
		StageManager.CurrentSession = session
		return session
	end
	return nil
end

local function tryCacheSessionFromCurrentPlayers(): StageSession?
	for _, player in Players:GetPlayers() do
		local session = tryCacheSessionFromPlayer(player)
		if session then
			return session
		end
	end
	return nil
end

local function buildStudioFallbackSession(stageNumber: number?): StageSession
	local resolvedStage = stageNumber
	if not resolvedStage then
		resolvedStage = 1
		warn("[StageManager] stageNumber nil → Studio fallback stage=1")
	end
	return {
		-- Studio 실행시 fallback.
		stageNumber = resolvedStage,
		difficulty = 1,		-- Easy
		roomId = "",
		capacity = 1,
		source = "studio",
	}
end

function StageManager.getCurrentSession(): StageSession?
	return StageManager.CurrentSession
end

function StageManager.init(stageNumber: number?)
	StageManager.CurrentStage = stageNumber

	local session = tryCacheSessionFromCurrentPlayers()
	if session then
		if stageNumber and session.stageNumber ~= stageNumber then
			warn(
				string.format(
					"[StageManager] TeleportData stage 불일치: place=%d teleport=%d",
					stageNumber,
					session.stageNumber
				)
			)
		end
		print(
			string.format(
				"[StageManager] TeleportData 캐시됨: stage=%d diff=%d roomId=%s cap=%d",
				session.stageNumber,
				session.difficulty,
				session.roomId,
				session.capacity
			)
		)
	elseif RunService:IsStudio() then
		StageManager.CurrentSession = buildStudioFallbackSession(stageNumber)
		local fallback = StageManager.CurrentSession :: StageSession
		print(
			string.format(
				"[StageManager] Studio fallback 사용: stage=%d diff=%d roomId=%s cap=%d",
				fallback.stageNumber,
				fallback.difficulty,
				fallback.roomId,
				fallback.capacity
			)
		)
	else
		warn("[StageManager] TeleportData 없음 (Live) - 세션 캐시 미설정")
	end

	print("[StageManager] 초기화 - 스테이지:", stageNumber, "설정:", StageHelper.getDisplayName(stageNumber, "kr"))
	GameManager.setPhase("Waiting")
end

function StageManager.onPlayerJoined(player: Player)
	print("[StageManager] 플레이어 입장:", player.Name)
	if StageManager.CurrentSession and StageManager.CurrentSession.source == "teleport" then
		return
	end
	local session = tryCacheSessionFromPlayer(player)
	if session then
		print(
			string.format(
				"[StageManager] TeleportData 캐시 갱신(from %s): stage=%d diff=%d roomId=%s cap=%d",
				player.Name,
				session.stageNumber,
				session.difficulty,
				session.roomId,
				session.capacity
			)
		)
	end
end

function StageManager.startStage()
	if GameManager.State.CurrentPhase == "Playing" then
		return
	end

	GameManager.setPhase("Playing")
	StageManager.StageStartedAt = os.clock()

	local partySize = #Players:GetPlayers()
	for _, player in Players:GetPlayers() do
		AchievementHelper.incrementByType(player, "PartyPlay", {
			partySize = partySize,
		})

		-- FeverGaugeStageStart: 스테이지 시작 시 N%만큼 게이지를 채운 상태로 시작
		local stageStartPercent = GameManager.getPlayerOptionTotal(player, "FeverGaugeStageStart")
		if stageStartPercent > 0 then
			FeverGaugeHandler.setGauge(player, stageStartPercent / 100)
		end

		-- FeverGaugeAutoCharge: N초마다 N%씩 자동 충전 (옵션 미보유 시 startAutoCharge 내부에서 무시됨)
		local autoChargeIntervalSec, autoChargePercent = GameManager.getPlayerOptionTotal(player, "FeverGaugeAutoCharge")
		FeverGaugeHandler.startAutoCharge(player, autoChargeIntervalSec, autoChargePercent)

		-- XpStageStart: 스테이지 시작 시 경험치 N만큼 획득한 상태로 시작
		local xpStageStart = GameManager.getPlayerOptionTotal(player, "XpStageStart")
		if xpStageStart > 0 then
			XpHandler.addXp(player, xpStageStart)
		end

		-- XpAutoCharge: N초마다 경험치 N만큼 자동 충전 (옵션 미보유 시 startAutoCharge 내부에서 무시됨)
		local xpAutoChargeIntervalSec, xpAutoChargeAmount = GameManager.getPlayerOptionTotal(player, "XpAutoCharge")
		XpHandler.startAutoCharge(player, xpAutoChargeIntervalSec, xpAutoChargeAmount)
	end

	print("[StageManager] 스테이지 시작 (partySize=", partySize, ")")
end

local function getStageNumberForAchievements(): number?
	local session = StageManager.CurrentSession
	if session then
		return session.stageNumber
	end
	return StageManager.CurrentStage
end

local function getClearElapsedSec(): number?
	if typeof(StageManager.StageStartedAt) ~= "number" then
		return nil
	end
	return math.max(0, math.floor(os.clock() - StageManager.StageStartedAt))
end

--- BattlePassPoint는 전용 옵션(StageRewardPassExpUp), 그 외 재화는 StageRewardCurrencyUp 적용
local function getRewardOptionType(currencyType: Types.CurrencyType): Types.OptionType
	if currencyType == "BattlePassPoint" then
		return "StageRewardPassExpUp"
	end
	return "StageRewardCurrencyUp"
end

--- 플레이어의 옵션 보유량(GameManager.getPlayerOptionTotal)만큼 % 증가 적용, 실제 지급 + 클라 표시용 목록 반환
local function applyClearRewardBonus(
	player: Player,
	clearReward: { Types.StageClearRewardEntry }
): { { currencyType: Types.CurrencyType, amount: number, isBonus: boolean } }
	local rewardsForClient = {}
	for _, reward in clearReward do
		local optionType = getRewardOptionType(reward.currencyType)
		local bonusPercent = GameManager.getPlayerOptionTotal(player, optionType)
		local isBonus = bonusPercent > 0
		local amount = if isBonus
			then math.floor(reward.amount * (1 + bonusPercent / 100) + 0.5)
			else reward.amount

		DataManager.addCurrency(player, reward.currencyType, amount)
		table.insert(rewardsForClient, {
			currencyType = reward.currencyType,
			amount = amount,
			isBonus = isBonus,
		})
	end
	return rewardsForClient
end

function StageManager.clearStage()
	if GameManager.State.CurrentPhase == "Ended" then
		return
	end

	GameManager.setPhase("Ended")
	print("[StageManager] 스테이지 클리어!")

	for _, player in Players:GetPlayers() do
		FeverGaugeHandler.stopAutoCharge(player)
		XpHandler.stopAutoCharge(player)
	end

	local difficulty = if StageManager.CurrentSession then StageManager.CurrentSession.difficulty else 2
	local clearReward = StageHelper.getClearReward(difficulty)

	local ev = ReplicatedStorage:FindFirstChild("StageClearedEvent")
	if not (ev and ev:IsA("RemoteEvent")) then
		warn("[StageManager] StageClearedEvent 없음 — ReplicatedStorage에 RemoteEvent 추가 필요")
	end

	for _, player in Players:GetPlayers() do
		MissionHelper.incrementProgress(player, 1)

		local stageNumber = getStageNumberForAchievements()
		local clearTimeSec = getClearElapsedSec()
		AchievementHelper.incrementByType(player, "StageClear")
		if stageNumber then
			AchievementHelper.incrementByType(player, "TargetStageClear", {
				stageNumber = stageNumber,
			})
			if clearTimeSec then
				AchievementHelper.incrementByType(player, "StageTimeClear", {
					stageNumber = stageNumber,
					clearTimeSec = clearTimeSec,
				})
			end
		end

		-- 플레이어 옵션 보유량(유물 등)만큼 % 보너스 적용 후 지급 — 플레이어마다 보유 옵션이 달라 개별 지급/전송
		local rewardsForClient = applyClearRewardBonus(player, clearReward)
		if ev and ev:IsA("RemoteEvent") then
			ev:FireClient(player, rewardsForClient)
		end
	end
end

function StageManager.failStage()
	GameManager.setPhase("Ended")
	print("[StageManager] 스테이지 실패")

	for _, player in Players:GetPlayers() do
		FeverGaugeHandler.stopAutoCharge(player)
		XpHandler.stopAutoCharge(player)
	end

	task.delay(3, function()
		for _, player in Players:GetPlayers() do
			PlaceManager.teleportToLobby(player)
		end
	end)
end

return StageManager
