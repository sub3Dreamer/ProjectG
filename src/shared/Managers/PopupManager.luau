local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")

local PopupManager = {}

PopupManager.PopupId = {
	Setting = "Setting",
	DailyReward = "DailyReward",
	Reward = "Reward",
	Gacha = "Gacha",
	Shop = "Shop",
	Inventory = "Inventory",
	Mission = "Mission",
	Achievement = "Achievement",
	BattlePass = "BattlePass",
	Relic = "Relic",
	LevelUp = "LevelUp",
	Costume = "Costume",
	Pvp = "Pvp",
}

export type PopupModule = {
	open: (...any) -> (),
	close: (() -> ())?,
}

if RunService:IsServer() then
	function PopupManager.init() end

	function PopupManager.pushPopup(): boolean
		return true
	end

	function PopupManager.setPopupOpenBlocked(_blocked: boolean) end

	function PopupManager.isPopupOpenBlocked(): boolean
		return false
	end

	function PopupManager.closeOpenPopups(_exceptClose: (() -> ())?) end

	function PopupManager.popPopup() end

	function PopupManager.getPopupDepth(): number
		return 0
	end

	function PopupManager.getRootGui(): ScreenGui?
		return nil
	end

	function PopupManager.getContentFrame(): GuiObject?
		return nil
	end

	function PopupManager.registerPopup(_id: string, _module: PopupModule) end

	function PopupManager.openPopup(_id: string, ...: any)
		warn(string.format(
			"[PopupManager] openPopup('%s') called on SERVER. This module is client-only.",
			tostring(_id)
		))
	end

	function PopupManager.closePopup(_id: string)
		warn(string.format(
			"[PopupManager] closePopup('%s') called on SERVER. This module is client-only.",
			tostring(_id)
		))
	end

	function PopupManager.playBounceEntrance(_menu: GuiObject) end

	return PopupManager
end

local TweenService = game:GetService("TweenService")

local POPUP_SCREEN_GUI_NAME = "PopupScreenGui"
local DIM_FADE_TIME = 0.5
local DIM_FADE_TWEEN = TweenInfo.new(DIM_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BOUNCE_DURATION = 0.5
local BOUNCE_OFFSET_Y = 0.02

-- Popup-on-popup ZIndex layering: solo popups rest at ZINDEX_POPUP_BASE with Dim at
-- ZINDEX_DIM_BASE (behind everything). When a popup opens on top of another popup,
-- the popup underneath drops to ZINDEX_POPUP_BASE, Dim rises to ZINDEX_DIM_STACKED
-- (between the two), and the new popup sits above at ZINDEX_POPUP_STACKED.
local ZINDEX_POPUP_BASE = 1
local ZINDEX_DIM_BASE = 0
local ZINDEX_DIM_STACKED = 2
local ZINDEX_POPUP_STACKED = 3

PopupManager.PopupDepth = 0

export type PushOptions = {
	dim: boolean?,
	blockInput: boolean?,
	close: (() -> ())?,
	closeOthers: boolean?,
	playEntranceAnimation: boolean?,
	rootGui: GuiObject?,
}

type StackEntry = {
	dim: boolean,
	blockInput: boolean,
	close: (() -> ())?,
	rootGui: GuiObject?,
	stackedOnPopup: GuiObject?,
}

local popupDepth = 0
local dimDepth = 0
local blockInputDepth = 0
local pushStack: { StackEntry } = {}
local savedTouchControlsEnabled: boolean? = nil
local overlayGui: ScreenGui? = nil
local dimFrame: GuiObject? = nil
local contentFrame: GuiObject? = nil
local dimDesignTransparency: number? = nil
local dimActiveTween: Tween? = nil
local initialized = false
local popupOpenBlocked = false
local openPopupClosers: { [() -> ()]: boolean } = {}
local closingOpenPopups = false
local registeredPopups: { [string]: PopupModule } = {}

local function cancelActiveDimFade()
	if dimActiveTween then
		pcall(function()
			dimActiveTween:Cancel()
		end)
	end
	dimActiveTween = nil
end

local function setDimImmediateTransparency(d: GuiObject, val: number)
	if d:IsA("CanvasGroup") then
		(d :: CanvasGroup).GroupTransparency = val
		return
	end
	pcall(function()
		(d :: any).BackgroundTransparency = val
	end)
end

local function startDimFadeIn()
	if not dimFrame or dimDesignTransparency == nil then
		return
	end
	local d = dimFrame
	cancelActiveDimFade()
	d.Visible = true
	setDimImmediateTransparency(d, 1)
	if d:IsA("CanvasGroup") then
		dimActiveTween = TweenService:Create(
			d :: Instance,
			DIM_FADE_TWEEN,
			{ GroupTransparency = dimDesignTransparency :: number }
		) :: Tween
	else
		dimActiveTween = TweenService:Create(
			d :: Instance,
			DIM_FADE_TWEEN,
			{ BackgroundTransparency = dimDesignTransparency :: number }
		) :: Tween
	end
	if dimActiveTween then
		dimActiveTween:Play()
	end
end

local function runDimFadeOutAndWait()
	if not dimFrame or dimDesignTransparency == nil then
		return
	end
	local d = dimFrame
	cancelActiveDimFade()
	if d:IsA("CanvasGroup") then
		dimActiveTween = TweenService:Create(d :: Instance, DIM_FADE_TWEEN, { GroupTransparency = 1 }) :: Tween
	else
		dimActiveTween = TweenService:Create(d :: Instance, DIM_FADE_TWEEN, { BackgroundTransparency = 1 }) :: Tween
	end
	if dimActiveTween then
		dimActiveTween:Play()
		dimActiveTween.Completed:Wait()
	end
	dimActiveTween = nil
	d.Visible = false
	setDimImmediateTransparency(d, dimDesignTransparency)
end

local function syncPopupDepthPublic()
	PopupManager.PopupDepth = popupDepth
end

local function showContent()
	if contentFrame then
		contentFrame.Visible = true
	end
end

local function hideContent()
	if contentFrame then
		contentFrame.Visible = false
	end
end

local function hideDimImmediate()
	cancelActiveDimFade()
	if dimFrame then
		dimFrame.Visible = false
	end
end

local function showDim()
	if dimFrame and dimDesignTransparency ~= nil then
		startDimFadeIn()
	elseif dimFrame then
		dimFrame.Visible = true
	end
end

local function hideDim()
	if dimFrame and dimDesignTransparency ~= nil then
		runDimFadeOutAndWait()
	elseif dimFrame then
		dimFrame.Visible = false
	end
end

local function disableTouchControls()
	if savedTouchControlsEnabled == nil then
		savedTouchControlsEnabled = GuiService.TouchControlsEnabled
	end
	pcall(function()
		GuiService.TouchControlsEnabled = false
	end)
end

local function restoreTouchControls()
	pcall(function()
		if savedTouchControlsEnabled ~= nil then
			GuiService.TouchControlsEnabled = savedTouchControlsEnabled
		end
	end)
	savedTouchControlsEnabled = nil
end

local function bindPopupScreenGui(gui: ScreenGui)
	cancelActiveDimFade()
	overlayGui = gui
	dimFrame = nil
	contentFrame = nil
	dimDesignTransparency = nil

	local content = gui:FindFirstChild("Content")
	if content and content:IsA("GuiObject") then
		contentFrame = content
	end

	local dim = content and content:FindFirstChild("Dim")
	if dim and dim:IsA("GuiObject") then
		dimFrame = dim
		if dim:IsA("CanvasGroup") then
			dimDesignTransparency = (dim :: CanvasGroup).GroupTransparency
		else
			local ok, v = pcall(function()
				return (dim :: any).BackgroundTransparency
			end)
			if ok and typeof(v) == "number" and v == v then
				dimDesignTransparency = v
			else
				dimDesignTransparency = 0.5
			end
		end
	end

	if dimFrame then
		dimFrame.Visible = false
		dimFrame.ZIndex = ZINDEX_DIM_BASE
	end
	if contentFrame then
		contentFrame.Visible = false
	end
end

function PopupManager.setPopupOpenBlocked(blocked: boolean)
	popupOpenBlocked = blocked
end

function PopupManager.isPopupOpenBlocked(): boolean
	return popupOpenBlocked
end

function PopupManager.closeOpenPopups(exceptClose: (() -> ())?)
	if closingOpenPopups then
		return
	end
	local toClose: { () -> () } = {}
	for close in openPopupClosers do
		if close ~= exceptClose then
			table.insert(toClose, close)
		end
	end
	closingOpenPopups = true
	for _, close in ipairs(toClose) do
		close()
	end
	closingOpenPopups = false
end

function PopupManager.init()
	if initialized then
		return
	end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild(POPUP_SCREEN_GUI_NAME)
	assert(gui:IsA("ScreenGui"), "[PopupManager] PopupScreenGui must be a ScreenGui")

	bindPopupScreenGui(gui :: ScreenGui)
	initialized = true
end

function PopupManager.pushPopup(options: PushOptions?): boolean
	if not initialized then
		PopupManager.init()
	end
	if popupOpenBlocked then
		return false
	end
	local opts = options or {}
	if opts.closeOthers then
		PopupManager.closeOpenPopups(opts.close)
	end

	local rootGui = opts.rootGui
	local stackedOnPopup: GuiObject? = nil
	if rootGui then
		for i = #pushStack, 1, -1 do
			local prevRootGui = pushStack[i].rootGui
			if prevRootGui and prevRootGui ~= rootGui then
				stackedOnPopup = prevRootGui
				break
			end
		end
	end

	local entry: StackEntry = {
		dim = opts.dim ~= false,
		blockInput = opts.blockInput ~= false,
		close = opts.close,
		rootGui = rootGui,
		stackedOnPopup = stackedOnPopup,
	}

	if rootGui then
		if stackedOnPopup then
			stackedOnPopup.ZIndex = ZINDEX_POPUP_BASE
			if dimFrame then
				dimFrame.ZIndex = ZINDEX_DIM_STACKED
			end
			rootGui.ZIndex = ZINDEX_POPUP_STACKED
		else
			rootGui.ZIndex = ZINDEX_POPUP_BASE
			if dimFrame then
				dimFrame.ZIndex = ZINDEX_DIM_BASE
			end
		end
	end

	table.insert(pushStack, entry)
	if entry.close then
		openPopupClosers[entry.close] = true
	end

	popupDepth += 1
	syncPopupDepthPublic()

	if popupDepth == 1 then
		showContent()
	end
	if entry.dim then
		dimDepth += 1
		if dimDepth == 1 then
			showDim()
		end
	elseif dimDepth == 0 then
		hideDimImmediate()
	end
	if entry.blockInput then
		blockInputDepth += 1
		if blockInputDepth == 1 then
			disableTouchControls()
		end
	end
	return true
end

function PopupManager.popPopup()
	if popupDepth <= 0 then
		return
	end
	local entry = table.remove(pushStack)
	popupDepth -= 1
	syncPopupDepthPublic()

	if entry then
		if entry.close then
			openPopupClosers[entry.close] = nil
		end
		if entry.dim then
			dimDepth -= 1
			if dimDepth <= 0 then
				dimDepth = 0
				hideDim()
			end
		end
		if entry.rootGui and entry.stackedOnPopup and dimFrame then
			dimFrame.ZIndex = ZINDEX_DIM_BASE
		end
		if entry.blockInput then
			blockInputDepth -= 1
			if blockInputDepth <= 0 then
				blockInputDepth = 0
				restoreTouchControls()
			end
		end
	end

	if popupDepth <= 0 then
		hideContent()
	end
end

function PopupManager.getPopupDepth(): number
	return popupDepth
end

function PopupManager.getRootGui(): ScreenGui?
	return overlayGui
end

function PopupManager.getContentFrame(): GuiObject?
	return contentFrame
end

function PopupManager.registerPopup(id: string, module: PopupModule)
	registeredPopups[id] = module
end

function PopupManager.openPopup(id: string, ...: any)
	local popup = registeredPopups[id]
	if not popup then
		warn("[PopupManager] Unregistered popup:", id)
		return
	end
	if not popup.open then
		warn("[PopupManager] Missing open:", id)
		return
	end
	popup.open(...)
end

function PopupManager.closePopup(id: string)
	local popup = registeredPopups[id]
	if not popup then
		warn("[PopupManager] Unregistered popup:", id)
		return
	end
	if popup.close then
		popup.close()
	end
end

function PopupManager.playBounceEntrance(menu: GuiObject)
	if not menu:IsA("CanvasGroup") then
		return
	end

	local origPos = menu.Position
	menu.Position = UDim2.new(
		origPos.X.Scale,
		origPos.X.Offset,
		origPos.Y.Scale - BOUNCE_OFFSET_Y,
		origPos.Y.Offset
	)
	menu.Rotation = math.random(2) == 1 and 1 or -1

	menu:TweenPosition(
		origPos,
		Enum.EasingDirection.Out,
		Enum.EasingStyle.Back,
		BOUNCE_DURATION,
		true
	)
	TweenService:Create(
		menu,
		TweenInfo.new(BOUNCE_DURATION, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Rotation = 0 }
	):Play()
end

return PopupManager