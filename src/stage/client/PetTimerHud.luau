--[[
	PetTimerHud (stage client)

	GameScreenGui.TimerHud.PetTimer: 서버(SpeechBubbleManager)의 전역 펫마킹 사이클과 동기화된 카운트다운 HUD.
	PetTimerPhaseEvent(FireAllClients)로 페이즈 전환 시점에 "그 순간 기준 남은 시간(초)"을 1회만
	받고, 이후는 로컬 os.clock() 기준으로 직접 카운트다운한다(GameTimer/Fever 게이지와 동일
	컨벤션 — 서버가 매초 다시 보내지 않음).

	GUI 트리: GameScreenGui.TimerHud.PetTimer
		IconUFO / IconPet — 페이즈에 따라 서로 배타적으로 노출
		TimeLeft (TextLabel) — "우주선 등장까지 : N초" / "펫 구출까지 : N초"
		XPBar.Fill (Frame) — 남은 시간 비율만큼 Size.X.Scale을 1→0으로 차감하는 게이지

	페이즈(PetMarkConfig 기준, 서버가 보내는 durationSec은 항상 MarkStartTime/RescueDuration
	전체 길이에서 시작한다):
	1. MarkStartTime — 다음 실제 마킹(t=MarkStartTime)까지 카운트다운.
	   - 앞의 (MarkStartTime - AreaNoticeTime)초 동안은 IconUFO + 카운트다운 노출.
	   - 마지막 AreaNoticeTime초(= UFO가 실제로 맵에 등장하는 구간)는 PetTimer 자체를 숨김.
	2. RescueDuration — 마킹 직후 구출 가능 시간(=SpeechBubble 3개 노출) 카운트다운. IconPet 노출.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PetMarkConfig = require(Shared.Config.PetMarkConfig)
local StringHelper = require(Shared.Helpers.StringHelper)

local PetTimerHud = {}

local LOCALE = "kr"
local PHASE_EVENT_NAME = "PetTimerPhaseEvent"
local PET_TIMER_NAME = "PetTimer"

local initialized = false
local petTimer: GuiObject? = nil
local iconUfo: GuiObject? = nil
local iconPet: GuiObject? = nil
local timeLeftLabel: TextLabel? = nil
local fillBar: GuiObject? = nil
local fillBaseSize: UDim2? = nil

-- 진행 중인 카운트다운 루프를 무효화하기 위한 세대 카운터. 새 페이즈 이벤트가 오면 증가시켜
-- 이전 루프가 다음 tick에서 스스로 멈추게 한다.
local countdownGeneration = 0

local function getPetTimer(): GuiObject?
	local player = Players.LocalPlayer
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return nil
	end
	local gameGui = playerGui:FindFirstChild("GameScreenGui")
	if not gameGui then
		return nil
	end
	local timerHud = gameGui:FindFirstChild("TimerHud")
	if not timerHud then
		return nil
	end
	local timer = timerHud:FindFirstChild(PET_TIMER_NAME)
	if timer and timer:IsA("GuiObject") then
		return timer
	end
	return nil
end

--- MarkStartTime 페이즈의 secondsLeft는 실제 마킹(t=MarkStartTime)까지 남은 시간이라 최대값이
--- MarkStartTime(40)이다. 하지만 "우주선 등장까지" 문구는 UFO가 실제로 등장하는 시점(t=MarkStartTime
--- -AreaNoticeTime, 그 뒤로는 PetTimer 자체가 숨겨짐)까지 남은 시간을 보여줘야 하므로 AreaNoticeTime을
--- 빼서 최대값이 (MarkStartTime-AreaNoticeTime)이 되도록 보정한다.
local function formatTimeLeftText(phase: string, secondsLeft: number): string
	local key = if phase == "RescueDuration" then "PetTimer_PetMarker_Notice" else "PetTimer_UFO_Notice"
	local displaySeconds = secondsLeft
	if phase == "MarkStartTime" then
		displaySeconds = math.max(0, secondsLeft - PetMarkConfig.AreaNoticeTime)
	end
	return string.format(StringHelper.get(key, LOCALE), displaySeconds)
end

--- MarkStartTime 페이즈의 마지막 AreaNoticeTime초(UFO가 실제로 맵에 등장하는 구간)는 PetTimer
--- 전체를 숨긴다. 그 외에는 페이즈에 맞는 아이콘만 배타적으로 노출한다.
local function applyPhaseVisibility(phase: string, secondsLeft: number)
	local hidden = phase == "MarkStartTime" and secondsLeft <= PetMarkConfig.AreaNoticeTime
	if petTimer then
		petTimer.Visible = not hidden
	end
	if iconUfo then
		iconUfo.Visible = phase == "MarkStartTime" and not hidden
	end
	if iconPet then
		iconPet.Visible = phase == "RescueDuration"
	end
end

--- 페이즈별 표시 구간의 전체 길이(초) 대비 남은 시간 비율만큼 Fill의 Size.X.Scale을 1→0으로
--- 차감한다. MarkStartTime은 formatTimeLeftText와 동일하게 AreaNoticeTime을 뺀 구간
--- (MarkStartTime-AreaNoticeTime)을 기준으로 삼는다(그 이후는 어차피 PetTimer 자체가 숨겨짐).
local function applyGaugeFill(phase: string, secondsLeft: number)
	if not (fillBar and fillBaseSize) then
		return
	end
	local displaySeconds = secondsLeft
	local total = PetMarkConfig.RescueDuration
	if phase == "MarkStartTime" then
		total = math.max(1, PetMarkConfig.MarkStartTime - PetMarkConfig.AreaNoticeTime)
		displaySeconds = math.max(0, secondsLeft - PetMarkConfig.AreaNoticeTime)
	end
	local fraction = math.clamp(displaySeconds / total, 0, 1)
	local base = fillBaseSize :: UDim2
	fillBar.Size = UDim2.new(fraction, base.X.Offset, base.Y.Scale, base.Y.Offset)
end

--- 게이지(Fill)만 매 프레임 갱신해 부드럽게 보간되도록 별도 루프로 분리한다. 텍스트/아이콘
--- 노출은 초 단위 그대로 유지하되(runCountdown), 게이지는 소수 단위 secondsLeft를 그대로 써서
--- 1초마다 뚝뚝 끊기지 않게 한다. countdownGeneration이 바뀌면(새 페이즈 이벤트) 스스로 멈춘다.
local function runGaugeFrameLoop(phase: string, durationSec: number, anchorClock: number, myGeneration: number)
	while countdownGeneration == myGeneration do
		local elapsed = os.clock() - anchorClock
		local secondsLeft = math.max(0, durationSec - elapsed)
		applyGaugeFill(phase, secondsLeft)
		if secondsLeft <= 0 then
			break
		end
		RunService.Heartbeat:Wait()
	end
end

--- durationSec: 서버가 이벤트를 쏜 "그 순간" 기준 남은 시간(초). 이후는 os.clock() 경과로
--- 직접 계산해 매초 자연스럽게 줄어들게 한다(단순 감산 누적이 아니라 앵커 기준 재계산이라
--- task.wait(1)의 오차가 누적되지 않는다).
local function runCountdown(phase: string, durationSec: number)
	countdownGeneration += 1
	local myGeneration = countdownGeneration
	local anchorClock = os.clock()

	task.spawn(runGaugeFrameLoop, phase, durationSec, anchorClock, myGeneration)

	while countdownGeneration == myGeneration do
		local elapsed = os.clock() - anchorClock
		local secondsLeft = math.max(0, math.ceil(durationSec - elapsed))

		applyPhaseVisibility(phase, secondsLeft)
		if timeLeftLabel then
			timeLeftLabel.Text = formatTimeLeftText(phase, secondsLeft)
		end

		if secondsLeft <= 0 then
			break
		end
		task.wait(1)
	end
end

function PetTimerHud.init()
	if initialized then
		return
	end
	initialized = true

	petTimer = getPetTimer()
	if not petTimer then
		warn("[PetTimerHud] GameScreenGui.PetTimer 없음")
		return
	end

	local iconUfoInst = petTimer:FindFirstChild("IconUFO")
	if iconUfoInst and iconUfoInst:IsA("GuiObject") then
		iconUfo = iconUfoInst
	else
		warn("[PetTimerHud] PetTimer.IconUFO (GuiObject) 없음")
	end

	local iconPetInst = petTimer:FindFirstChild("IconPet")
	if iconPetInst and iconPetInst:IsA("GuiObject") then
		iconPet = iconPetInst
	else
		warn("[PetTimerHud] PetTimer.IconPet (GuiObject) 없음")
	end

	local timeLeftInst = petTimer:FindFirstChild("TimeLeft")
	if timeLeftInst and timeLeftInst:IsA("TextLabel") then
		timeLeftLabel = timeLeftInst
	else
		warn("[PetTimerHud] PetTimer.TimeLeft (TextLabel) 없음")
	end

	local xpBarInst = petTimer:FindFirstChild("XPBar")
	local fillInst = xpBarInst and xpBarInst:FindFirstChild("Fill")
	if fillInst and fillInst:IsA("GuiObject") then
		fillBar = fillInst
		fillBaseSize = fillInst.Size
	else
		warn("[PetTimerHud] PetTimer.XPBar.Fill (GuiObject) 없음")
	end

	-- 첫 페이즈 이벤트가 오기 전까지는 숨김.
	petTimer.Visible = false

	ReplicatedStorage:WaitForChild(PHASE_EVENT_NAME).OnClientEvent:Connect(function(phase: any, durationSec: any)
		if typeof(phase) ~= "string" or typeof(durationSec) ~= "number" then
			return
		end
		runCountdown(phase, durationSec)
	end)
end

return PetTimerHud
