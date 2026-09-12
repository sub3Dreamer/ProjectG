--[[
	SettingPopup (lobby client)

	GUI 트리: PopupScreenGui.Content.SettingPopup (CanvasGroup)
		Container.ScrollingContainer
			Music — UI_Toggle 태그 GuiButton (Action: ToggleMusicMute)
			MusicVolume.VolumeFrame
			SFX — UI_Toggle 태그 GuiButton (Action: ToggleSFXMute)
			SFXVolume.VolumeFrame
		Top.CloseButton

]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)
local SoundManager = require(Shared.Managers.SoundManager)
local StringBinder = require(Shared.Helpers.StringBinder)

local SettingPopup = {}

local TOGGLE_COLOR_ON = Color3.fromRGB(85, 255, 0)
local TOGGLE_COLOR_OFF = Color3.fromRGB(255, 50, 50)
local UI_TOGGLE_TAG = "UI_Toggle"
local UI_TOGGLE_STATUS_TAG = "UI_Toggle_Status"

type SoundControls = {
	musicToggle: GuiButton,
	musicVolumeFrame: Instance,
	sfxToggle: GuiButton,
	sfxVolumeFrame: Instance,
	musicVolumeDown: GuiButton,
	musicVolumeUp: GuiButton,
	sfxVolumeDown: GuiButton,
	sfxVolumeUp: GuiButton,
}

local initialized = false
local volumeListenersRegistered = false
type ActiveSession = {
	close: () -> (),
	controls: SoundControls,
}

local activeSession: ActiveSession? = nil

local function findToggleStatusLabel(button: GuiButton): TextLabel?
	for _, descendant in button:GetDescendants() do
		if descendant:IsA("TextLabel") and CollectionService:HasTag(descendant, UI_TOGGLE_STATUS_TAG) then
			return descendant
		end
	end
	return nil
end

local function applyToggleColor(target: GuiObject, muted: boolean)
	target.BackgroundColor3 = muted and TOGGLE_COLOR_OFF or TOGGLE_COLOR_ON
end

local function setToggleStatus(button: GuiButton, muted: boolean)
	local status = findToggleStatusLabel(button)
	if status then
		status.Text = muted and "OFF" or "ON"
	end

	if button:IsA("GuiObject") then
		applyToggleColor(button :: GuiObject, muted)
	end

	local background = button:FindFirstChild("Background")
	if background and background:IsA("GuiObject") then
		applyToggleColor(background :: GuiObject, muted)
	end
end

local function refreshMusicToggle(controls: SoundControls)
	setToggleStatus(controls.musicToggle, SoundManager.isMusicMuted())
end

local function refreshSfxToggle(controls: SoundControls)
	setToggleStatus(controls.sfxToggle, SoundManager.isSfxMuted())
end

local function refreshUI(controls: SoundControls)
	refreshMusicToggle(controls)
	refreshSfxToggle(controls)
	SoundManager.applyMusicVolumeUI(controls.musicVolumeFrame)
	SoundManager.applySfxVolumeUI(controls.sfxVolumeFrame)
end

local function findGuiButton(parent: Instance, name: string): GuiButton?
	local inst = parent:FindFirstChild(name)
	if inst and inst:IsA("GuiButton") then
		return inst
	end
	return nil
end

local function findToggleButton(row: Instance): GuiButton?
	if row:IsA("GuiButton") and CollectionService:HasTag(row, UI_TOGGLE_TAG) then
		return row
	end

	for _, descendant in row:GetDescendants() do
		if descendant:IsA("GuiButton") and CollectionService:HasTag(descendant, UI_TOGGLE_TAG) then
			return descendant
		end
	end
	return nil
end

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

local function prepareSettingRow(row: Instance, toggle: GuiButton)
	prepareClickableButton(toggle)

	for _, child in row:GetChildren() do
		if child ~= toggle and child:IsA("GuiObject") then
			local gui = child :: GuiObject
			if child.Name == "Background" or child:IsA("GuiObject") and not child:IsA("GuiButton") then
				gui.Active = false
			end
		end
	end
end

local function resolveSoundControls(root: Instance): SoundControls?
	local container = root:FindFirstChild("Container")
	if not container then
		warn("[SettingPopup] Container 없음")
		return nil
	end

	local scrolling = container:FindFirstChild("ScrollingContainer")
	if not scrolling then
		warn("[SettingPopup] Container.ScrollingContainer 없음")
		return nil
	end

	local musicRow = scrolling:FindFirstChild("Music")
	local musicVolumeRow = scrolling:FindFirstChild("MusicVolume")
	local sfxRow = scrolling:FindFirstChild("SFX")
	local sfxVolumeRow = scrolling:FindFirstChild("SFXVolume")
	if not (musicRow and musicVolumeRow and sfxRow and sfxVolumeRow) then
		warn("[SettingPopup] Music / MusicVolume / SFX / SFXVolume 행 없음")
		return nil
	end

	local musicToggle = findToggleButton(musicRow)
	local sfxToggle = findToggleButton(sfxRow)
	if not musicToggle then
		warn("[SettingPopup] Music 행에 UI_Toggle 태그 GuiButton 없음")
		return nil
	end
	if not sfxToggle then
		warn("[SettingPopup] SFX 행에 UI_Toggle 태그 GuiButton 없음")
		return nil
	end

	prepareSettingRow(musicRow, musicToggle)
	prepareSettingRow(sfxRow, sfxToggle)

	local musicVolumeFrame = musicVolumeRow:FindFirstChild("VolumeFrame")
	local sfxVolumeFrame = sfxVolumeRow:FindFirstChild("VolumeFrame")
	if not musicVolumeFrame then
		warn("[SettingPopup] MusicVolume.VolumeFrame 없음")
		return nil
	end
	if not sfxVolumeFrame then
		warn("[SettingPopup] SFXVolume.VolumeFrame 없음")
		return nil
	end

	local musicDown = findGuiButton(musicVolumeFrame, "VolumeDownButton")
	local musicUp = findGuiButton(musicVolumeFrame, "VolumeUpButton")
	local sfxDown = findGuiButton(sfxVolumeFrame, "VolumeDownButton")
	local sfxUp = findGuiButton(sfxVolumeFrame, "VolumeUpButton")
	if not (musicDown and musicUp and sfxDown and sfxUp) then
		warn("[SettingPopup] VolumeDownButton / VolumeUpButton 없음")
		return nil
	end

	return {
		musicToggle = musicToggle,
		musicVolumeFrame = musicVolumeFrame,
		sfxToggle = sfxToggle,
		sfxVolumeFrame = sfxVolumeFrame,
		musicVolumeDown = musicDown,
		musicVolumeUp = musicUp,
		sfxVolumeDown = sfxDown,
		sfxVolumeUp = sfxUp,
	}
end

local function getSettingPopupRoot(): GuiObject?
	if not PopupManager.getRootGui() then
		PopupManager.init()
	end
	local content = PopupManager.getContentFrame()
	if not content then
		return nil
	end
	local rootInst = content:FindFirstChild("SettingPopup")
	if rootInst and rootInst:IsA("GuiObject") then
		return rootInst :: GuiObject
	end
	return nil
end

local function registerVolumeListeners()
	if volumeListenersRegistered then
		return
	end
	volumeListenersRegistered = true

	SoundManager.onMusicVolumeChanged(function()
		if not activeSession or not activeSession.controls then
			return
		end
		local controls = activeSession.controls
		refreshMusicToggle(controls)
		SoundManager.applyMusicVolumeUI(controls.musicVolumeFrame)
	end)

	SoundManager.onSfxVolumeChanged(function()
		if not activeSession or not activeSession.controls then
			return
		end
		local controls = activeSession.controls
		refreshSfxToggle(controls)
		SoundManager.applySfxVolumeUI(controls.sfxVolumeFrame)
	end)
end

local function connectButton(button: GuiButton, handler: () -> ()): RBXScriptConnection
	prepareClickableButton(button)
	return button.Activated:Connect(handler)
end

function SettingPopup.open()
	registerVolumeListeners()

	local rootGui = getSettingPopupRoot()
	if not rootGui then
		warn("[SettingPopup] Content.SettingPopup 없음")
		return
	end
	StringBinder.applySubtreeOnce(rootGui)

	local controls = resolveSoundControls(rootGui)
	if not controls then
		return
	end

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[SettingPopup] Content 없음")
		return
	end

	local top = rootGui:FindFirstChild("Top")
	local closeInst = top and top:FindFirstChild("CloseButton")
	if not (closeInst and closeInst:IsA("GuiButton")) then
		warn("[SettingPopup] Top.CloseButton 없음")
		return
	end
	local closeBtn = closeInst :: GuiButton

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
	end

	local pushOptions = {
		dim = false,
		blockInput = false,
		close = close,
		closeOthers = true,
		playEntranceAnimation = true,
		rootGui = rootGui,
	}
	if not PopupManager.pushPopup(pushOptions) then
		contentGui.Active = prevContentActive
		rootGui.Active = prevRootActive
		return
	end
	rootGui.Visible = true
	if pushOptions.playEntranceAnimation then
		PopupManager.playBounceEntrance(rootGui)
	end

	refreshUI(controls)

	table.insert(connections, connectButton(controls.musicToggle, function()
		SoundManager.toggleMusicMute()
		refreshMusicToggle(controls)
		SoundManager.applyMusicVolumeUI(controls.musicVolumeFrame)
		print("[SettingPopup] Music", SoundManager.isMusicMuted() and "OFF" or "ON")
	end))
	table.insert(connections, connectButton(controls.sfxToggle, function()
		SoundManager.toggleSFXMute()
		refreshSfxToggle(controls)
		SoundManager.applySfxVolumeUI(controls.sfxVolumeFrame)
	end))

	table.insert(connections, connectButton(controls.musicVolumeDown, function()
		SoundManager.musicVolumeDown(controls.musicVolumeFrame)
	end))
	table.insert(connections, connectButton(controls.musicVolumeUp, function()
		SoundManager.musicVolumeUp(controls.musicVolumeFrame)
	end))
	table.insert(connections, connectButton(controls.sfxVolumeDown, function()
		SoundManager.sfxVolumeDown(controls.sfxVolumeFrame)
	end))
	table.insert(connections, connectButton(controls.sfxVolumeUp, function()
		SoundManager.sfxVolumeUp(controls.sfxVolumeFrame)
	end))
	table.insert(connections, connectButton(closeBtn, close))

	activeSession = {
		close = close,
		controls = controls,
	}
end

function SettingPopup.close()
	if activeSession then
		activeSession.close()
	end
end

function SettingPopup.init()
	if initialized then
		return
	end
	initialized = true
	print("[SettingPopup] 초기화 완료")
end

return SettingPopup
