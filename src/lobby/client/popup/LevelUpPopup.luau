--[[
	LevelUpPopup (lobby client)

	GUI 트리: PopupScreenGui.Content.LevelUpPopup (CanvasGroup)
		BackgroundButton — 클릭 시 닫기
		Container.Rewards.Reward.LevelUpIcon.TxtLevel — 레벨 숫자 표시
		Container.RibbonRoot.ImgLevelUp
		Container.TouchToContinue

	열기:
		LevelUpPopup.open(level, onClose?)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)
local SoundManager = require(Shared.Managers.SoundManager)
local StringBinder = require(Shared.Helpers.StringBinder)

local LevelUpPopup = {}

local POPUP_ROOT_NAME = "LevelUpPopup"

local initialized = false
local activeSession: { close: () -> () }? = nil

local function prepareClickableButton(button: GuiButton)
	button.Active = true
	if button:IsA("GuiObject") then
		local gui = button :: GuiObject
		gui.ZIndex = math.max(gui.ZIndex, 2)
	end
	pcall(function()
		(button :: any).Interactable = true
	end)
end

local function getLevelUpPopupRoot(): GuiObject?
	if not PopupManager.getRootGui() then
		PopupManager.init()
	end
	local content = PopupManager.getContentFrame()
	if not content then
		return nil
	end
	local rootInst = content:FindFirstChild(POPUP_ROOT_NAME)
	if rootInst and rootInst:IsA("GuiObject") then
		return rootInst :: GuiObject
	end
	return nil
end

local function applyLevel(rootGui: GuiObject, level: number): boolean
	local container = rootGui:FindFirstChild("Container")
	if not container then
		warn("[LevelUpPopup] Container 없음")
		return false
	end

	local rewardsInst = container:FindFirstChild("Rewards")
	local rewardInst = rewardsInst and rewardsInst:FindFirstChild("Reward")
	local levelUpIconInst = rewardInst and rewardInst:FindFirstChild("LevelUpIcon")
	local txtLevelInst = levelUpIconInst and levelUpIconInst:FindFirstChild("TxtLevel")
	if not (txtLevelInst and txtLevelInst:IsA("TextLabel")) then
		warn("[LevelUpPopup] Container.Rewards.Reward.LevelUpIcon.TxtLevel 없음")
		return false
	end

	(txtLevelInst :: TextLabel).Text = tostring(level)
	return true
end

function LevelUpPopup.open(level: number, onClose: (() -> ())?)
	if activeSession then
		activeSession.close()
	end

	local function finishOnClose()
		if onClose then
			onClose()
		end
	end

	if typeof(level) ~= "number" or level ~= level then
		warn("[LevelUpPopup] 잘못된 인자:", level)
		finishOnClose()
		return
	end
	local normalizedLevel = math.floor(level)

	local rootGui = getLevelUpPopupRoot()
	if not rootGui then
		warn("[LevelUpPopup] Content.LevelUpPopup 없음")
		finishOnClose()
		return
	end
	StringBinder.applySubtreeOnce(rootGui)

	local bgBtnInst = rootGui:FindFirstChild("BackgroundButton")
	if not (bgBtnInst and bgBtnInst:IsA("GuiButton")) then
		warn("[LevelUpPopup] BackgroundButton 없음")
		finishOnClose()
		return
	end
	local backgroundBtn = bgBtnInst :: GuiButton

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[LevelUpPopup] Content 없음")
		finishOnClose()
		return
	end

	local contentGui = content :: GuiObject
	local prevContentActive = contentGui.Active
	local prevRootActive = rootGui.Active
	local wasRootVis = rootGui.Visible

	contentGui.Active = false
	rootGui.Active = false

	local closed = false
	local connections: { RBXScriptConnection } = {}

	local function close()
		if closed then
			return
		end
		closed = true
		for _, c in ipairs(connections) do
			c:Disconnect()
		end
		rootGui.Visible = wasRootVis
		contentGui.Active = prevContentActive
		rootGui.Active = prevRootActive
		PopupManager.popPopup()
		if activeSession and activeSession.close == close then
			activeSession = nil
		end
		finishOnClose()
	end

	if not PopupManager.pushPopup({
		dim = true,
		blockInput = true,
		close = close,
		closeOthers = false,
		rootGui = rootGui,
	}) then
		contentGui.Active = prevContentActive
		rootGui.Active = prevRootActive
		finishOnClose()
		return
	end

	rootGui.Visible = true
	if not applyLevel(rootGui, normalizedLevel) then
		close()
		return
	end

	SoundManager.playSfx(SoundManager.Sfx.RewardReveal)

	prepareClickableButton(backgroundBtn)
	table.insert(connections, backgroundBtn.Activated:Connect(close))

	activeSession = { close = close }
end

function LevelUpPopup.close()
	if activeSession then
		activeSession.close()
	end
end

function LevelUpPopup.init()
	if initialized then
		return
	end
	initialized = true
	print("[LevelUpPopup] 초기화 완료")
end

return LevelUpPopup
