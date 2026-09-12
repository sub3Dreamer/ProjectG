local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)
local SoundManager = require(Shared.Managers.SoundManager)
local StageEndState = require(script.Parent.Parent.StageEndState)

local GameOverPopup = {}

local TIME_OVER_HOLD_SEC = 1.5
local TEXT_TIME_OVER = "Time Over"
local TEXT_STAGE_FAILED = "Stage Failed"
local TEXT_CROSS_FADE = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

local function tweenTextTransparency(label: TextLabel, stroke: UIStroke?, target: number)
	local t = TweenService:Create(label, TEXT_CROSS_FADE, { TextTransparency = target })
	t:Play()
	if stroke then
		TweenService:Create(stroke, TEXT_CROSS_FADE, { Transparency = target }):Play()
	end
	t.Completed:Wait()
end

--- 타이머 만료: Time Over(페이드 인) → 유지 → Stage\\nFailed(아웃→인) + 버튼. Remote: StageRetry / ReturnToLobby
function GameOverPopup.start()
	-- 아래 연출(tween/task.wait)이 여러 프레임에 걸쳐 yield되는 동안, 뒤늦게 도착한 PetSavedEvent가
	-- PetSavedPopup을 열어 이 팝업 위에 겹치지 않도록 가장 먼저 표시해둔다.
	StageEndState.markEnded()
	local StageHUD = require(script.Parent.Parent.StageHUD) :: any

	if not PopupManager.getRootGui() then
		PopupManager.init()
	end

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[GameOverPopup] Content 없음 (PopupManager.init, PopupScreenGui.Content 확인)")
		return
	end

	local root = content:FindFirstChild("GameOverPopup")
	if not (root and root:IsA("GuiObject")) then
		warn("[GameOverPopup] Content.GameOverPopup 을 찾을 수 없습니다")
		return
	end
	local rootGui = root :: GuiObject

	local message = root:FindFirstChild("Message")
	local retryInst = root:FindFirstChild("RetryButton", true)
	local lobbyInst = root:FindFirstChild("LobbyButton", true)
	if not (message and message:IsA("TextLabel")) then
		warn("[GameOverPopup] Message (TextLabel) 없음")
		return
	end
	if not (retryInst and retryInst:IsA("GuiButton")) or not (lobbyInst and lobbyInst:IsA("GuiButton")) then
		warn("[GameOverPopup] RetryButton / LobbyButton (GuiButton) 없음")
		return
	end

	local retryB = retryInst :: GuiButton
	local lobbyB = lobbyInst :: GuiButton
	local messageLabel = message :: TextLabel
	local uiStroke = messageLabel:FindFirstChildOfClass("UIStroke")

	local wasMsg = messageLabel.Text
	local wasTextT = messageLabel.TextTransparency
	local wasStrokeT = messageLabel.TextStrokeTransparency
	local wasUiStrokeT = uiStroke and uiStroke.Transparency
	local wasRootVis = rootGui.Visible
	local wasRetryVis = retryB.Visible
	local wasLobbyVis = lobbyB.Visible
	local wasRetryActive = retryB.Active
	local wasLobbyActive = lobbyB.Active

	local stageRetryEvent = ReplicatedStorage:WaitForChild("StageRetryRequestEvent") :: RemoteEvent
	local returnToLobbyEvent = ReplicatedStorage:WaitForChild("ReturnToLobbyRequestEvent") :: RemoteEvent

	local done = false
	local connRetry: RBXScriptConnection? = nil
	local connLobby: RBXScriptConnection? = nil

	local function finish()
		if done then
			return
		end
		done = true
		if connRetry then
			connRetry:Disconnect()
		end
		if connLobby then
			connLobby:Disconnect()
		end
		messageLabel.Text = wasMsg
		messageLabel.TextTransparency = wasTextT
		messageLabel.TextStrokeTransparency = wasStrokeT
		if uiStroke and wasUiStrokeT then
			uiStroke.Transparency = wasUiStrokeT
		end
		rootGui.Visible = wasRootVis
		retryB.Visible = wasRetryVis
		lobbyB.Visible = wasLobbyVis
		retryB.Active = wasRetryActive
		lobbyB.Active = wasLobbyActive
		pcall(function()
			StageHUD.setGameplayInputLocked(false)
		end)
		PopupManager.popPopup()
	end

	-- 게임오버 팝업이 뜰 때 PetSavedPopup 등 다른 stage 팝업이 같이 떠 있으면 안 되므로 강제로 닫는다.
	PopupManager.pushPopup({ close = finish, rootGui = rootGui, closeOthers = true })
	rootGui.Visible = true
	retryB.Visible = false
	lobbyB.Visible = false
	retryB.Active = false
	lobbyB.Active = false

	messageLabel.TextStrokeTransparency = wasStrokeT
	messageLabel.Text = TEXT_TIME_OVER
	messageLabel.TextTransparency = 1
	if uiStroke then
		uiStroke.Transparency = 1
	end
	tweenTextTransparency(messageLabel, uiStroke, 0)

	task.wait(TIME_OVER_HOLD_SEC)

	tweenTextTransparency(messageLabel, uiStroke, 1)
	messageLabel.Text = TEXT_STAGE_FAILED
	SoundManager.playSfx(SoundManager.Sfx.StageFail)
	tweenTextTransparency(messageLabel, uiStroke, 0)

	retryB.Visible = true
	lobbyB.Visible = true
	retryB.Active = true
	lobbyB.Active = true

	connRetry = retryB.Activated:Connect(function()
		stageRetryEvent:FireServer()
		finish()
	end)
	connLobby = lobbyB.Activated:Connect(function()
		returnToLobbyEvent:FireServer()
		finish()
	end)
end

return GameOverPopup
