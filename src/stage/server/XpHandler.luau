--[[
	서버 권한 경험치. Character Attribute(XP, XPNext)로 복제 → 모든 클라이언트가 머리 위 게이지에 사용.
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameSettings = require(Shared.Config.GameSettings)
local CharacterScaleCurve = require(Shared.Config.CharacterScaleCurve)
local LevelXpCurve = require(Shared.Config.LevelXpCurve)
local DamageableObjectStats = require(Shared.Utils.DamageableObjectStats)
local LevelDiffCurve = require(Shared.Utils.LevelDiffCurve)
local LeaderstatsHandler = require(Shared.Managers.LeaderstatsHandler)

local XpHandler = {}

local xpCfg = GameSettings.XP

local function xpCurveMaxLevel(): number
	local m = LevelXpCurve.meta
	if typeof(m) == "table" and typeof(m.maxLevel) == "number" then
		return math.max(1, math.floor(m.maxLevel))
	end
	warn("[XpHandler] LevelXpCurve.meta.maxLevel 없음 — 100 사용")
	return 100
end

-- 레벨(표시용) 1부터
local playerLevel: { [number]: number } = {}
local playerXpIntoLevel: { [number]: number } = {}
local autoChargeTasksByUserId: { [number]: thread } = {}

local applyScaleCallback: ((Player, number) -> ())? = nil

local function cancelAutoCharge(player: Player)
	local uid = player.UserId
	local existing = autoChargeTasksByUserId[uid]
	if existing then
		task.cancel(existing)
		autoChargeTasksByUserId[uid] = nil
	end
end

local function characterScaleCurveMaxLevel(): number
	local m = CharacterScaleCurve.meta
	if typeof(m) == "table" and typeof(m.maxLevel) == "number" then
		return math.max(1, math.floor(m.maxLevel))
	end
	return xpCurveMaxLevel()
end

--- 레벨별 캐릭터 스케일 커브
function XpHandler.scaleForLevel(level: number): number
	local s = GameSettings.Scale
	local arr = CharacterScaleCurve.scaleByLevel
	local idx = math.clamp(math.floor(level + 0.5), 1, characterScaleCurveMaxLevel())
	local value = typeof(arr) == "table" and (arr[tostring(idx)] or arr[idx]) or nil
	if typeof(value) == "number" and value == value and value > 0 then
		return math.clamp(value, s.MinScale, s.MaxScale)
	end
	return math.clamp(s.PlayerScale, s.MinScale, s.MaxScale)
end

function XpHandler.getLevel(userId: number): number
	return playerLevel[userId] or 1
end

function XpHandler.setApplyScaleCallback(cb: ((Player, number) -> ())?)
	applyScaleCallback = cb
end

local function xpNeededForNext(level: number): number
	local t = LevelXpCurve.xpToNextByLevel
	if typeof(t) == "table" then
		local v = t[tostring(level)] or t[level]
		if typeof(v) == "number" and v == v and v >= 0 then
			return math.max(0, math.floor(v))
		end
	end
	warn("[XpHandler] xpToNextByLevel에 레벨 정의 없음:", level)
	return 1
end

local function pushAttributes(player: Player)
	local uid = player.UserId
	local level = playerLevel[uid] or 1
	local into = playerXpIntoLevel[uid] or 0
	local need = xpNeededForNext(level)

	LeaderstatsHandler.setLevel(player, level)

	local char = player.Character
	if not char then
		return
	end
	char:SetAttribute("XP", into)
	char:SetAttribute("XPNext", need)
	char:SetAttribute("XPLevel", level)
end

function XpHandler.init()
	Players.PlayerAdded:Connect(function(player)
		playerLevel[player.UserId] = 1
		playerXpIntoLevel[player.UserId] = 0
		player.CharacterAdded:Connect(function()
			task.defer(function()
				pushAttributes(player)
			end)
		end)
		if player.Character then
			task.defer(function()
				pushAttributes(player)
			end)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		playerLevel[player.UserId] = nil
		playerXpIntoLevel[player.UserId] = nil
		cancelAutoCharge(player)
	end)

	for _, p in Players:GetPlayers() do
		playerLevel[p.UserId] = playerLevel[p.UserId] or 1
		playerXpIntoLevel[p.UserId] = playerXpIntoLevel[p.UserId] or 0
		p.CharacterAdded:Connect(function()
			task.defer(function()
				pushAttributes(p)
			end)
		end)
		if p.Character then
			task.defer(function()
				pushAttributes(p)
			end)
		end
	end
end

--- 파괴·퀘스트 등 서버 로직에서 호출
function XpHandler.addXp(player: Player, amount: number)
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return
	end

	local uid = player.UserId
	local levelBefore = playerLevel[uid] or 1
	local level = levelBefore
	local into = playerXpIntoLevel[uid] or 0
	local maxLevel = xpCurveMaxLevel()

	local levelUpChargeAmount = player:GetAttribute("XpChargeOnLevelUpAmount")
	if typeof(levelUpChargeAmount) ~= "number" or levelUpChargeAmount ~= levelUpChargeAmount then
		levelUpChargeAmount = 0
	end

	into = into + amount

	while level < maxLevel do
		local need = xpNeededForNext(level)
		if into < need then
			break
		end
		into = into - need
		level = level + 1
		if levelUpChargeAmount > 0 then
			into = into + levelUpChargeAmount
		end
	end

	if level >= maxLevel then
		level = maxLevel
		into = xpNeededForNext(level)
	end

	playerLevel[uid] = level
	playerXpIntoLevel[uid] = into

	-- XPLevel 등을 먼저 반영해야 ScaleModule·Fever가 WalkSpeed 계산 시 올바른 레벨을 읽음
	-- (콜백이 먼저면 이전 레벨 기준 속도가 남거나, task.wait 중 Fever 토글과 엇갈릴 수 있음)
	pushAttributes(player)

	if level ~= levelBefore and applyScaleCallback then
		applyScaleCallback(player, level)
	end
end

--- 현재 레벨의 경험치 바만 감소. 레벨은 유지하고 0 아래로는 내려가지 않음.
function XpHandler.removeXpFromGauge(player: Player, amount: number)
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return
	end

	local uid = player.UserId
	local into = playerXpIntoLevel[uid] or 0
	into = math.max(0, into - amount)
	playerXpIntoLevel[uid] = into

	pushAttributes(player)
end

--- TestPanel.Scale +/- 등: 레벨을 1만큼 조절
function XpHandler.addLevelDelta(player: Player, delta: number)
	if delta ~= 1 and delta ~= -1 then
		return
	end

	local uid = player.UserId
	local levelBefore = playerLevel[uid] or 1
	local maxL = xpCurveMaxLevel()
	local minL = 1
	local newLevel = math.clamp(levelBefore + delta, minL, maxL)
	if newLevel == levelBefore then
		return
	end

	playerLevel[uid] = newLevel
	playerXpIntoLevel[uid] = 0

	pushAttributes(player)

	if applyScaleCallback then
		applyScaleCallback(player, newLevel)
	end
end

--- XpGainBonusOnDestroy 옵션(오브젝트 파괴로 얻는 경험치에 N% 추가 획득) 적용
local function applyDestroyGainBonus(player: Player, xp: number): number
	local bonusPercent = player:GetAttribute("XpGainBonusOnDestroyPercent")
	if typeof(bonusPercent) == "number" and bonusPercent > 0 then
		return math.floor(xp * (1 + bonusPercent / 100) + 0.5)
	end
	return xp
end

--- AttackDamageCurve.damageMultiplierByLevelDiff와 같은 balancing 표(경험치 컬럼)를 사용해,
--- 캐릭터 레벨과 파괴한 건물 Tier 차이에 따라 경험치 배율을 구한다(공격력 보정과 반대 방향).
local function getLevelGapXpMultiplier(player: Player, model: Model): (number, number)
	local level = XpHandler.getLevel(player.UserId)
	local targetTier = DamageableObjectStats.tierOnModel(model) or 1
	local mult = LevelDiffCurve.lookupMultiplier(LevelXpCurve.xpMultiplierByLevelDiff, level - targetTier, 1)
	return mult, targetTier
end

--- 반환값(finalXp, gapMult, rawXp, targetTier)은 CombatHandler의 스튜디오 전용 디버그 로그용.
--- 지급할 경험치가 없으면(모델에 XP 설정 없음) 전부 nil.
function XpHandler.grantXpFromDestroy(player: Player, model: Model): (number?, number?, number?, number?)
	local rawXp = DamageableObjectStats.xpRewardOnModel(model)
	if not rawXp or rawXp <= 0 then
		return nil, nil, nil, nil
	end
	local mult, targetTier = getLevelGapXpMultiplier(player, model)
	local gapXp = math.floor(rawXp * mult + 0.5)
	local finalXp = applyDestroyGainBonus(player, gapXp)
	XpHandler.addXp(player, finalXp)
	return finalXp, mult, rawXp, targetTier
end

function XpHandler.grantXpFromDestroyedLevel(player: Player, objectLevel: number)
	if objectLevel <= 0 then
		return
	end
	local base = xpCfg.XpPerLevelDestroyed or 15
	XpHandler.addXp(player, applyDestroyGainBonus(player, base * objectLevel))
end

--[[
	XpAutoCharge 옵션(intervalSec마다 경험치 amount만큼) 주기적 자동 충전 시작.
	intervalSec/amount 둘 다 0보다 커야 실제로 타이머가 시작됨(옵션 미보유 시 아무 것도 안 함).
	기존 타이머가 있으면 먼저 취소 후 새로 시작 — 스테이지 재시작 등 재진입에도 안전.
]]
function XpHandler.startAutoCharge(player: Player, intervalSec: number, amount: number)
	cancelAutoCharge(player)
	if typeof(intervalSec) ~= "number" or intervalSec <= 0 then
		return
	end
	if typeof(amount) ~= "number" or amount <= 0 then
		return
	end

	local uid = player.UserId
	autoChargeTasksByUserId[uid] = task.spawn(function()
		while true do
			task.wait(intervalSec)
			if not player.Parent then
				break
			end
			XpHandler.addXp(player, amount)
		end
	end)
end

--- 스테이지 종료/실패 시 정리(누수 방지)
function XpHandler.stopAutoCharge(player: Player)
	cancelAutoCharge(player)
end

return XpHandler
