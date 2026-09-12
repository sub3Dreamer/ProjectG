local StageHUD = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameSettings = require(Shared.Config.GameSettings)
local PetMarkConfig = require(Shared.Config.PetMarkConfig)
local ScaleModule = require(Shared.Utils.ScaleModule)
local BossIntroCamera = require(script.Parent.BossIntroCamera)
local BossIntroPopup = require(script.Parent.popup.BossIntroPopup)
local LoadingPopup = require(script.Parent.popup.LoadingPopup)
local StageBossLocator = require(script.Parent.StageBossLocator)
local StageStartBossFacing = require(script.Parent.StageStartBossFacing)
local GameStartPopup = require(script.Parent.popup.GameStartPopup)
local GameOverPopup = require(script.Parent.popup.GameOverPopup)
local GameClearPopup = require(script.Parent.popup.GameClearPopup)
local SoundManager = require(Shared.Managers.SoundManager)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

StageHUD.IsAutoAttackEnabled = false
--- true면 이동(가상 조이스틱)·전투 입력 차단
StageHUD.IsGameplayInputLocked = false

local hudSavedTouchControlsEnabled: boolean? = nil
local hudGameplayLockListenersReady = false

local function applyWalkSpeedLockToHumanoid(humanoid: Humanoid)
	humanoid.WalkSpeed = 0
end

local function refreshWalkSpeedAfterGameplayUnlock()
	local ch = player.Character
	if ch then
		ScaleModule.applyWalkSpeedForCharacter(ch)
	end
end

local function ensureGameplayInputLockListeners()
	if hudGameplayLockListenersReady then
		return
	end
	hudGameplayLockListenersReady = true

	player.CharacterAdded:Connect(function(character: Model)
		if not StageHUD.IsGameplayInputLocked then
			return
		end
		task.defer(function()
			local h = character:WaitForChild("Humanoid", 15)
			if h and h:IsA("Humanoid") and StageHUD.IsGameplayInputLocked then
				applyWalkSpeedLockToHumanoid(h)
			end
		end)
	end)
end

function StageHUD.setGameplayInputLocked(locked: boolean)
	if locked == StageHUD.IsGameplayInputLocked then
		return
	end
	StageHUD.IsGameplayInputLocked = locked

	if locked then
		ensureGameplayInputLockListeners()

		if hudSavedTouchControlsEnabled == nil then
			hudSavedTouchControlsEnabled = GuiService.TouchControlsEnabled
		end
		pcall(function()
			GuiService.TouchControlsEnabled = false
		end)

		local ch = player.Character
		if ch then
			local h = ch:FindFirstChildOfClass("Humanoid")
			if h then
				applyWalkSpeedLockToHumanoid(h)
			end
		end
	else
		pcall(function()
			if hudSavedTouchControlsEnabled ~= nil then
				GuiService.TouchControlsEnabled = hudSavedTouchControlsEnabled
			end
		end)
		hudSavedTouchControlsEnabled = nil

		refreshWalkSpeedAfterGameplayUnlock()
	end
end

local TIMER_WARN_ORANGE_AT_OR_BELOW_SEC = 60
local TIMER_WARN_RED_AT_OR_BELOW_SEC = 10
local TIMER_COLOR_ORANGE = Color3.fromRGB(255, 140, 40)
local TIMER_COLOR_RED = Color3.fromRGB(230, 55, 55)

local gameTimerDurationSec = GameSettings.StageClearTimeout or 300
local gameTimerLabelRef: TextLabel? = nil
local gameTimerDefaultTextColor = Color3.fromRGB(255, 255, 255)
local gameTimerRunSerial = 0
--- 클리어 시 경과시간 = gameTimerDurationSec - gameTimerLastRemaining
local gameTimerLastRemaining: number = gameTimerDurationSec

local function resolveGameTimerDurationFromServer()
	local inst = ReplicatedStorage:FindFirstChild("StageTimeLimitSec")
	if inst and inst:IsA("IntValue") and inst.Value > 0 then
		gameTimerDurationSec = inst.Value
		gameTimerLastRemaining = gameTimerDurationSec
	end
end

local function formatGameTimerText(totalSeconds: number): string
	local m = math.max(0, math.floor(totalSeconds / 60))
	local s = math.max(0, totalSeconds % 60)
	return string.format("%d:%02d", m, s)
end

local function applyGameTimerStyle(remainingSec: number)
	local label = gameTimerLabelRef
	if not label then
		return
	end
	if remainingSec <= TIMER_WARN_RED_AT_OR_BELOW_SEC then
		label.TextColor3 = TIMER_COLOR_RED
	elseif remainingSec <= TIMER_WARN_ORANGE_AT_OR_BELOW_SEC then
		label.TextColor3 = TIMER_COLOR_ORANGE
	else
		label.TextColor3 = gameTimerDefaultTextColor
	end
end

local function updateGameTimerDisplay(remainingSec: number)
	local label = gameTimerLabelRef
	if not label then
		return
	end
	label.Text = formatGameTimerText(remainingSec)
	applyGameTimerStyle(remainingSec)
end

local function bindGameTimer(gameGui: Instance)
	local timerHud = gameGui:FindFirstChild("TimerHud")
	local frame = timerHud and timerHud:FindFirstChild("GameTimer")
	local textInst = frame and frame:FindFirstChild("TimerText")
	if textInst and textInst:IsA("TextLabel") then
		gameTimerLabelRef = textInst
		gameTimerDefaultTextColor = textInst.TextColor3
		updateGameTimerDisplay(gameTimerDurationSec)
	else
		warn("[StageHUD] GameScreenGui.TimerHud.GameTimer.TimerText(TextLabel) 없음 — 타이머 비활성")
	end
end

local function onGameTimerExpired()
	gameTimerRunSerial += 1
	StageHUD.setGameplayInputLocked(true)
	task.spawn(function()
		GameOverPopup.start()
	end)
end

--- 스튜디오 테스트용: 타이머 만료와 동일하게 GameOverPopup 트리거
function StageHUD.testTriggerGameOver()
	onGameTimerExpired()
end

local function startGameTimerCountdown()
	gameTimerRunSerial += 1
	local serial = gameTimerRunSerial
	if not gameTimerLabelRef then
		return
	end

	task.spawn(function()
		local remaining = gameTimerDurationSec
		while serial == gameTimerRunSerial and remaining > 0 do
			gameTimerLastRemaining = remaining
			updateGameTimerDisplay(remaining)
			task.wait(1)
			remaining -= 1
		end
		if serial ~= gameTimerRunSerial then
			return
		end
		updateGameTimerDisplay(0)
		applyGameTimerStyle(0)
		onGameTimerExpired()
	end)
end

local function onStageClearedFromServer(rewards: any)
	print("[StageHUD] StageClearedEvent 수신, GameClearPopup 호출 예정")
	local r = gameTimerLastRemaining
	gameTimerRunSerial += 1
	local elapsed = math.clamp(gameTimerDurationSec - r, 0, gameTimerDurationSec)
	StageHUD.setGameplayInputLocked(true)
	task.spawn(function()
		GameClearPopup.start(elapsed, rewards)
	end)
end

local HUD_MESSAGE_NAMES = { "FeverTime" }
local hudMessageObjects: { [string]: GuiObject } = {}
local hudMessageAutoHideSerial = 0

local spaceShipLabel: TextLabel? = nil
local spaceShipStroke: UIStroke? = nil
local spaceShipBasePosition: UDim2? = nil
local spaceShipAnimSerial = 0

local function applyHideAllHudMessagesOnly()
	for _, g in pairs(hudMessageObjects) do
		g.Visible = false
	end
end

function StageHUD.hideAllMessages()
	hudMessageAutoHideSerial += 1
	applyHideAllHudMessagesOnly()
end

--- 네 개 중 하나만 보이게 함. 잘못된 이름이면 전부 끔.
--- visibleSeconds: 양수면 해당 초 후 자동으로 전부 끔. 생략·0 이하면 유지(수동 hideAllMessages까지).
function StageHUD.showMessage(messageName: string, visibleSeconds: number?)
	hudMessageAutoHideSerial += 1
	local mySerial = hudMessageAutoHideSerial
	applyHideAllHudMessagesOnly()
	local g = hudMessageObjects[messageName]
	if g then
		g.Visible = true
	end
	if typeof(visibleSeconds) == "number" and visibleSeconds == visibleSeconds and visibleSeconds > 0 then
		task.delay(visibleSeconds, function()
			if hudMessageAutoHideSerial ~= mySerial then
				return
			end
			applyHideAllHudMessagesOnly()
			hudMessageAutoHideSerial += 1
		end)
	end
end

function StageHUD.showFeverTimeMessage(visibleSeconds: number?)
	StageHUD.showMessage("FeverTime", visibleSeconds)
end

function StageHUD.hideFeverTimeMessage()
	local g = hudMessageObjects["FeverTime"]
	if g then
		g.Visible = false
	end
end

function StageHUD.beginFeverDrainAfterIntro()
	-- StageHUD.init에서 피버 게이지 UI가 있을 때만 연결됨
end

local function bindHudMessages(gameGui: Instance)
	local messagesFrame = gameGui:FindFirstChild("Messages")
	if not (messagesFrame and messagesFrame:IsA("GuiObject")) then
		warn("[StageHUD] GameScreenGui에 Messages(Frame 등 GuiObject)가 없습니다. FeverTime 토글을 쓸 수 없습니다.")
		return
	end

	for _, name in ipairs(HUD_MESSAGE_NAMES) do
		local inst = messagesFrame:FindFirstChild(name)
		if inst and inst:IsA("GuiObject") then
			hudMessageObjects[name] = inst
			inst.Visible = false
		else
			warn("[StageHUD] Messages.", name, "GuiObject 없음 — 이름·부모를 확인하세요.")
		end
	end

	messagesFrame.ChildAdded:Connect(function(inst)
		if inst:IsA("GuiObject") then
			for _, name in ipairs(HUD_MESSAGE_NAMES) do
				if inst.Name == name then
					hudMessageObjects[name] = inst
					inst.Visible = false
					break
				end
			end
		end
	end)

	local spaceShipInst = messagesFrame:FindFirstChild("SpaceShip")
	if spaceShipInst and spaceShipInst:IsA("TextLabel") then
		spaceShipLabel = spaceShipInst
		spaceShipBasePosition = spaceShipInst.Position
		spaceShipInst.Visible = false

		local strokeInst = spaceShipInst:FindFirstChild("UIStroke")
		if strokeInst and strokeInst:IsA("UIStroke") then
			spaceShipStroke = strokeInst
		else
			warn("[StageHUD] Messages.SpaceShip.UIStroke 없음 — 우주선 안내 연출의 테두리 페이드를 건너뜁니다.")
		end
	else
		warn("[StageHUD] Messages.SpaceShip(TextLabel) 없음 — 우주선 안내 연출을 표시할 수 없습니다.")
	end
end

--- PetMarkAreaNoticeEvent(AreaNoticeTime 시작 시점)에 맞춰 SpaceShip 텍스트를 잠깐 노출한다.
--- TextTransparency/UIStroke.Transparency 페이드와 PositionX 슬라이드(1 -> 0.5 -> 0)를 동시에
--- 재생하고(각 0.5초 트윈 + 중간 대기시간 유지), 연출이 모두 끝나면 Visible을 다시 끈다.
local SPACE_SHIP_TWEEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function spaceShipPositionAtXScale(xScale: number): UDim2
	local base = spaceShipBasePosition :: UDim2
	return UDim2.new(xScale, base.X.Offset, base.Y.Scale, base.Y.Offset)
end

local function playSpaceShipNoticeAsync()
	if not (spaceShipLabel and spaceShipBasePosition) then
		return
	end

	spaceShipAnimSerial += 1
	local mySerial = spaceShipAnimSerial

	spaceShipLabel.Visible = true
	spaceShipLabel.TextTransparency = 1
	spaceShipLabel.Position = spaceShipPositionAtXScale(1)
	if spaceShipStroke then
		spaceShipStroke.Transparency = 1
	end

	local slideInTween = TweenService:Create(spaceShipLabel, SPACE_SHIP_TWEEN_INFO, { Position = spaceShipPositionAtXScale(0.5) })
	TweenService:Create(spaceShipLabel, SPACE_SHIP_TWEEN_INFO, { TextTransparency = 0 }):Play()
	if spaceShipStroke then
		TweenService:Create(spaceShipStroke, SPACE_SHIP_TWEEN_INFO, { Transparency = 0 }):Play()
	end
	slideInTween:Play()
	slideInTween.Completed:Wait()
	if spaceShipAnimSerial ~= mySerial then
		return
	end

	task.wait(PetMarkConfig.AreaNoticeTime - 1)
	if spaceShipAnimSerial ~= mySerial then
		return
	end

	local slideOutTween = TweenService:Create(spaceShipLabel, SPACE_SHIP_TWEEN_INFO, { Position = spaceShipPositionAtXScale(0) })
	TweenService:Create(spaceShipLabel, SPACE_SHIP_TWEEN_INFO, { TextTransparency = 1 }):Play()
	if spaceShipStroke then
		TweenService:Create(spaceShipStroke, SPACE_SHIP_TWEEN_INFO, { Transparency = 1 }):Play()
	end
	slideOutTween:Play()
	slideOutTween.Completed:Wait()
	if spaceShipAnimSerial ~= mySerial then
		return
	end

	spaceShipLabel.Visible = false
end

function StageHUD.playSpaceShipNotice()
	task.spawn(playSpaceShipNoticeAsync)
end

function StageHUD.init()
	print("[StageHUD] 스테이지 HUD 초기화")

	local stageTimeLimitInst = ReplicatedStorage:WaitForChild("StageTimeLimitSec", 10)
	if stageTimeLimitInst and stageTimeLimitInst:IsA("IntValue") and stageTimeLimitInst.Value > 0 then
		gameTimerDurationSec = stageTimeLimitInst.Value
		gameTimerLastRemaining = gameTimerDurationSec
	else
		resolveGameTimerDurationFromServer()
		warn("[StageHUD] StageTimeLimitSec 없음 — GameSettings.StageClearTimeout 사용:", gameTimerDurationSec)
	end

	local scaleChangeEvent = ReplicatedStorage:WaitForChild("ScaleChangeEvent")
	local scaleUpdateEvent = ReplicatedStorage:WaitForChild("ScaleUpdateEvent")
	local stageGameplayStartEvent = ReplicatedStorage:WaitForChild("StageGameplayStartEvent") :: RemoteEvent

	local scaleLabelRef: TextLabel? = nil
	local pendingScale: number = GameSettings.Scale.PlayerScale
	local currentLevel = 1

	local function formatScaleText(n: number): string
		if math.abs(n - math.floor(n + 0.5)) < 0.05 then
			return tostring(math.floor(n + 0.5))
		end
		return string.format("%.1f", n)
	end

	local function applyScaleToLabel(n: number)
		if scaleLabelRef then
			scaleLabelRef.Text = string.format("Level %d: %s", currentLevel, formatScaleText(n))
		end
	end

	local function bindCharacter(character: Model)
		pendingScale = ScaleModule.getCharacterScale(character)

		local function refreshLevel()
			local level = character:GetAttribute("XPLevel")
			if typeof(level) == "number" and level == level and level >= 1 then
				currentLevel = math.floor(level + 0.5)
			else
				currentLevel = 1
			end

			applyScaleToLabel(pendingScale)
		end

		refreshLevel()
		character:GetAttributeChangedSignal("XPLevel"):Connect(refreshLevel)
	end

	scaleUpdateEvent.OnClientEvent:Connect(function(newScale: number)
		if typeof(newScale) ~= "number" then
			return
		end
		pendingScale = newScale
		applyScaleToLabel(newScale)
	end)

	local gameGui = playerGui:WaitForChild("GameScreenGui")
	bindHudMessages(gameGui)
	bindGameTimer(gameGui)
	ReplicatedStorage:WaitForChild("StageClearedEvent").OnClientEvent:Connect(function(rewards: any)
		onStageClearedFromServer(rewards)
	end)
	ReplicatedStorage:WaitForChild("PetMarkAreaNoticeEvent").OnClientEvent:Connect(function(_areas: any)
		StageHUD.playSpaceShipNotice()
	end)
	ensureGameplayInputLockListeners()

	player.CharacterAdded:Connect(function(character: Model)
		bindCharacter(character)
	end)
	if player.Character then
		bindCharacter(player.Character)
	end

	local leftPanel = gameGui:WaitForChild("LeftPanel")
	local testPanel = leftPanel:WaitForChild("TestPanel")

	local feverGaugeSyncEvent = ReplicatedStorage:WaitForChild("FeverGaugeSyncEvent")
	local feverFxToggleRequestEvent = ReplicatedStorage:WaitForChild("FeverFxToggleRequestEvent")

	local feverFrame = gameGui:FindFirstChild("Fever", true)
	local gaugeFrame: Instance? = nil
	local feverValueLabel: TextLabel? = nil
	if feverFrame and feverFrame:IsA("Frame") then
		gaugeFrame = feverFrame:FindFirstChild("Gauge")
		local vInst = feverFrame:FindFirstChild("Value")
		if vInst and vInst:IsA("TextLabel") then
			feverValueLabel = vInst
		end
	end

	if feverFrame and feverFrame:IsA("Frame") and gaugeFrame and gaugeFrame:IsA("Frame") then
		local yScale = gaugeFrame.Size.Y.Scale
		local yOffset = gaugeFrame.Size.Y.Offset
		local lastGaugeT = 0
		local lastServerGaugeT = 0
		local feverModeAttrConn: RBXScriptConnection? = nil
		local feverDrainConn: RBXScriptConnection? = nil
		local feverDrainStartClock = 0

		local fmCfg = GameSettings.Combat.FeverMode
		local baseFeverDurationSec = 10
		if typeof(fmCfg) == "table" and typeof(fmCfg.DurationSeconds) == "number" and fmCfg.DurationSeconds > 0 then
			baseFeverDurationSec = fmCfg.DurationSeconds
		end
		-- 실제 지속시간(유물 FeverDurationUp 보너스 포함)은 서버가 Fever ON 시 FeverDurationSeconds Attribute로 알려줌
		local feverDurationSec = baseFeverDurationSec

		-- 게이지 0%: 노랑 (255,255,0) → 100%: 빨강 (255,0,0) 선형 보간
		local function feverGaugeFillColor(fill01: number): Color3
			local t = math.clamp(fill01, 0, 1)
			local g = math.floor(255 * (1 - t) + 0.5)
			return Color3.fromRGB(255, g, 0)
		end

		local function applyGaugeVisual(fill01: number)
			local t = math.clamp(fill01, 0, 1)
			lastGaugeT = t
			gaugeFrame.Size = UDim2.new(t, 0, yScale, yOffset)
			gaugeFrame.BackgroundColor3 = feverGaugeFillColor(t)
			if feverValueLabel then
				feverValueLabel.Text = string.format("%d%%", math.floor(t * 100 + 0.5))
			end
		end

		local function stopFeverDrain()
			if feverDrainConn then
				feverDrainConn:Disconnect()
				feverDrainConn = nil
			end
		end

		local function showFeverIntroGauge()
			lastGaugeT = 1
			gaugeFrame.Size = UDim2.new(1, 0, yScale, yOffset)
			gaugeFrame.BackgroundColor3 = feverGaugeFillColor(1)
			if feverValueLabel then
				feverValueLabel.Text = string.format("%ds", feverDurationSec)
			end
		end

		local function startFeverDrain()
			if feverDrainConn then
				return
			end
			feverDrainStartClock = os.clock()
			feverDrainConn = RunService.RenderStepped:Connect(function()
				local ch = player.Character
				if not ch or ch:GetAttribute("FeverMode") ~= true then
					stopFeverDrain()
					applyGaugeVisual(lastServerGaugeT)
					return
				end
				local elapsed = os.clock() - feverDrainStartClock
				local remain = math.max(0, feverDurationSec - elapsed)
				local fill = 0
				if feverDurationSec > 0 then
					fill = remain / feverDurationSec
				end
				lastGaugeT = fill
				gaugeFrame.Size = UDim2.new(fill, 0, yScale, yOffset)
				gaugeFrame.BackgroundColor3 = feverGaugeFillColor(fill)
				if feverValueLabel then
					local sec = math.max(0, math.ceil(remain - 1e-4))
					feverValueLabel.Text = string.format("%ds", sec)
				end
			end)
		end

		function StageHUD.beginFeverDrainAfterIntro()
			local ch = player.Character
			if not ch or ch:GetAttribute("FeverMode") ~= true then
				return
			end
			startFeverDrain()
		end

		local function applyServerGauge(n: number)
			local prev = lastServerGaugeT
			lastServerGaugeT = math.clamp(n, 0, 1)
			-- 게이지가 100%에 도달하는 순간(이전엔 미만) → 예전 FeverButton 클릭과 동일하게 서버에 토글 요청
			if not feverDrainConn and prev < 0.999 and lastServerGaugeT >= 0.999 then
				feverFxToggleRequestEvent:FireServer()
				SoundManager.playSfx(SoundManager.Sfx.Fever)
			end
			if feverDrainConn then
				return
			end
			applyGaugeVisual(lastServerGaugeT)
		end

		local function onFeverModeAttributeChanged()
			local ch = player.Character
			local active = ch and ch:GetAttribute("FeverMode") == true
			if active then
				local durationOverride = ch and ch:GetAttribute("FeverDurationSeconds")
				feverDurationSec = if typeof(durationOverride) == "number" and durationOverride > 0
					then durationOverride
					else baseFeverDurationSec
				StageHUD.showFeverTimeMessage()
				showFeverIntroGauge()
			else
				stopFeverDrain()
				applyGaugeVisual(lastServerGaugeT)
				StageHUD.hideFeverTimeMessage()
			end
		end

		local function attachFeverModeListener()
			if feverModeAttrConn then
				feverModeAttrConn:Disconnect()
				feverModeAttrConn = nil
			end
			local ch = player.Character
			if not ch then
				return
			end
			feverModeAttrConn = ch:GetAttributeChangedSignal("FeverMode"):Connect(onFeverModeAttributeChanged)
			onFeverModeAttributeChanged()
		end

		applyServerGauge(0)
		task.defer(function()
			attachFeverModeListener()
		end)
		player.CharacterAdded:Connect(function()
			task.defer(function()
				attachFeverModeListener()
			end)
		end)

		feverGaugeSyncEvent.OnClientEvent:Connect(function(n: number)
			if typeof(n) ~= "number" or n ~= n then
				return
			end
			applyServerGauge(n)
		end)
	else
		if not (gaugeFrame and gaugeFrame:IsA("Frame")) then
			warn("[StageHUD] GameScreenGui 하위 `Fever`와 그 안의 Frame `Gauge`가 없으면 피버 게이지를 표시할 수 없습니다.")
		end
	end

	local scalePanel = testPanel:WaitForChild("Scale")
	local addButton = scalePanel:WaitForChild("AddButton")
	local subtractButton = scalePanel:WaitForChild("SubtractButton")
	local scaleLabel = scalePanel:WaitForChild("ScaleTextLabel")
	scaleLabelRef = scaleLabel :: TextLabel

	applyScaleToLabel(pendingScale)

	local autoAttackButton = leftPanel:WaitForChild("AutoAttackButton", 15)
	if autoAttackButton and autoAttackButton:IsA("GuiButton") then
		local buttonImage = autoAttackButton:FindFirstChild("ButtonImage")
		local buttonHighlightImage = buttonImage and buttonImage:FindFirstChild("ButtonHighlightImage")

		local function isImageInstance(inst: Instance?): boolean
			return inst ~= nil and (inst:IsA("ImageLabel") or inst:IsA("ImageButton"))
		end

		local defaultButtonImageColor = isImageInstance(buttonImage) and buttonImage.ImageColor3
		local defaultButtonHighlightImageColor = isImageInstance(buttonHighlightImage) and buttonHighlightImage.ImageColor3

		local function applyAutoAttackColor(color: Color3?)
			if isImageInstance(buttonImage) then
				buttonImage.ImageColor3 = color or defaultButtonImageColor
			end
			if isImageInstance(buttonHighlightImage) then
				buttonHighlightImage.ImageColor3 = color or defaultButtonHighlightImageColor
			end
		end

		autoAttackButton.MouseButton1Click:Connect(function()
			StageHUD.IsAutoAttackEnabled = not StageHUD.IsAutoAttackEnabled

			if StageHUD.IsAutoAttackEnabled then
				applyAutoAttackColor(Color3.fromRGB(200, 50, 50))
				print("[StageHUD] 자동 공격 ON")
			else
				applyAutoAttackColor(nil)
				print("[StageHUD] 자동 공격 OFF")
			end
		end)
	else
		warn("[StageHUD] GameScreenGui.LeftPanel에 AutoAttackButton(TextButton/ImageButton)이 없습니다. 스테이지 GUI를 확인하세요.")
	end

	local returnToLobbyEvent = ReplicatedStorage:WaitForChild("ReturnToLobbyRequestEvent") :: RemoteEvent
	local exitPanel = gameGui:FindFirstChild("ExitPanel")
	local exitButton = exitPanel and exitPanel:FindFirstChild("ExitButton")
	if exitButton and exitButton:IsA("GuiButton") then
		local leaving = false
		exitButton.Activated:Connect(function()
			if leaving then
				return
			end
			leaving = true
			returnToLobbyEvent:FireServer()
		end)
	else
		warn("[StageHUD] GameScreenGui.ExitPanel에 ExitButton(TextButton/ImageButton)이 없습니다.")
	end

	addButton.MouseButton1Click:Connect(function()
		scaleChangeEvent:FireServer(1)
	end)

	subtractButton.MouseButton1Click:Connect(function()
		scaleChangeEvent:FireServer(-1)
	end)

	task.defer(function()
		StageHUD.setGameplayInputLocked(true)
		if BossIntroCamera.Enabled then
			LoadingPopup.show()
			local boss = StageBossLocator.waitForBoss(LoadingPopup.updateProgress)
			LoadingPopup.close()
			if boss then
				BossIntroPopup.begin(boss)
			end
		end
		StageStartBossFacing.apply()
		BossIntroCamera.play(function()
			GameStartPopup.play(function()
				SoundManager.startBgm(SoundManager.BgmMode.Stage)
				stageGameplayStartEvent:FireServer()
				StageHUD.setGameplayInputLocked(false)
				startGameTimerCountdown()
			end)
		end)
	end)
end

return StageHUD
