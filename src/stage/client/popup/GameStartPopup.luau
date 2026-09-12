local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)
local SoundManager = require(Shared.Managers.SoundManager)

local GameStartPopup = {}

local COUNT_NAMES = { "3", "2", "1" } :: { string }
local COUNTDOWN_FROM_SCALE = 0.5
local COUNTDOWN_TO_SCALE = 1
local LETS_GO_TEXT = "Let's Go"
local LETS_GO_FROM_SCALE = 2
local LETS_GO_TO_SCALE = 1

local COUNTDOWN_TWEEN = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- 숫자 하나당(표시~다음 숫자 전까지) 벽시계 합이 이 값(초). 트윈 끝난 뒤 나머지는 task.wait로 맞춤.
local COUNTDOWN_SEC_PER_DIGIT = 1
local LETS_GO_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PAUSE_AFTER_LETS_GO_SEC = 0.35

local function getOrCreateUiScale(gui: GuiObject): UIScale
	local s = gui:FindFirstChildOfClass("UIScale")
	if s then
		return s
	end
	local n = Instance.new("UIScale")
	n.Scale = 1
	n.Parent = gui
	return n
end

local function playScaleTween(uiScale: UIScale, from: number, to: number, tweenInfo: TweenInfo)
	uiScale.Scale = from
	local tw = TweenService:Create(uiScale, tweenInfo, { Scale = to })
	tw:Play()
	tw.Completed:Wait()
end

--- 3,2,1 + Let's Go 연출 후 onComplete. UI 없으면 경고하고 즉시 onComplete.
function GameStartPopup.play(onComplete: (() -> ())?)
	if not PopupManager.getRootGui() then
		PopupManager.init()
	end

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[GameStartPopup] Content 없음 (PopupScreenGui / PopupManager.init 확인)")
		if onComplete then
			onComplete()
		end
		return
	end

	local popup = content:FindFirstChild("GameStartPopup")
	if not (popup and popup:IsA("GuiObject")) then
		warn("[GameStartPopup] Content.GameStartPopup 을 찾을 수 없습니다")
		if onComplete then
			onComplete()
		end
		return
	end

	local message = popup:FindFirstChild("Message")
	if not (message and message:IsA("TextLabel")) then
		warn("[GameStartPopup] GameStartPopup.Message (TextLabel) 을 찾을 수 없습니다")
		if onComplete then
			onComplete()
		end
		return
	end

	local messageLabel = message :: TextLabel
	local uiScale = getOrCreateUiScale(messageLabel)
	local originalText = messageLabel.Text
	local popupGui = popup :: GuiObject
	local wasVisible = popupGui.Visible
	local closed = false

	local function forceClose()
		if closed then
			return
		end
		closed = true
		messageLabel.Text = originalText
		uiScale.Scale = 1
		popupGui.Visible = wasVisible
		PopupManager.popPopup()
	end

	PopupManager.pushPopup({ close = forceClose })
	popupGui.Visible = true

		SoundManager.playSfx(SoundManager.Sfx.Countdown)

	local tweenDur = COUNTDOWN_TWEEN.Time
	local waitAfterCountdownTween = math.max(0, COUNTDOWN_SEC_PER_DIGIT - tweenDur)
	for _, text in COUNT_NAMES do
		messageLabel.Text = text
		playScaleTween(uiScale, COUNTDOWN_FROM_SCALE, COUNTDOWN_TO_SCALE, COUNTDOWN_TWEEN)
		if waitAfterCountdownTween > 0 then
			task.wait(waitAfterCountdownTween)
		end
	end

	messageLabel.Text = LETS_GO_TEXT
	playScaleTween(uiScale, LETS_GO_FROM_SCALE, LETS_GO_TO_SCALE, LETS_GO_TWEEN)
	if PAUSE_AFTER_LETS_GO_SEC > 0 then
		task.wait(PAUSE_AFTER_LETS_GO_SEC)
	end

	forceClose()

	if onComplete then
		onComplete()
	end
end

return GameStartPopup
