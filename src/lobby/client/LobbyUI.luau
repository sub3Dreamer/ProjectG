--[[
	LobbyUI (lobby client)

	StarterGui -> PlayerGui 로 복제된 LobbyScreenGui, PopupScreenGui 안에서
	CollectionService 태그 UI_Button 이 붙은 GuiButton 에 호버/클릭 피드백을 적용한다.
		- Activated: Press SFX
		- MouseEnter: Hover SFX + UI_Button_Icon 태그 ImageLabel 1.05x 확대
		- MouseLeave: UI_Button_Icon 태그 ImageLabel 원래 크기로 복귀
]]

local LobbyUI = {}

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)

local UI_BUTTON_TAG = "UI_Button"
local UI_BUTTON_ICON_TAG = "UI_Button_Icon"
local TARGET_SCREEN_GUI_NAMES = { "LobbyScreenGui", "PopupScreenGui" }

local ICON_HOVER_SCALE = UDim2.new(1.05, 0, 1.05, 0)
local ICON_DEFAULT_SCALE = UDim2.new(1, 0, 1, 0)
local ICON_HOVER_TWEEN_TIME = 0.1
local ICON_LEAVE_TWEEN_TIME = 0.3

type SfxModule = { Play: (self: SfxModule, name: string) -> () }

local initialized = false
local boundButtons: { [GuiButton]: boolean } = {}

local function resolveSfx(): SfxModule
	local essentials = ReplicatedStorage:FindFirstChild("RBLXEssentials")
	local soundSystem = essentials and essentials:FindFirstChild("SoundSystem")
	local sfxModule = soundSystem and soundSystem:FindFirstChild("SFXSystem")
	if sfxModule then
		return require(sfxModule) :: SfxModule
	end
	return { Play = function() end }
end

local function findButtonIcon(button: GuiButton): ImageLabel?
	for _, descendant in button:GetDescendants() do
		if descendant:IsA("ImageLabel") and CollectionService:HasTag(descendant, UI_BUTTON_ICON_TAG) then
			return descendant
		end
	end
	return nil
end

local function bindButton(button: GuiButton, sfx: SfxModule)
	if boundButtons[button] then
		return
	end
	boundButtons[button] = true

	local icon = findButtonIcon(button)

	button.Activated:Connect(function()
		sfx:Play("Press")
	end)

	button.MouseEnter:Connect(function()
		sfx:Play("Hover")
		if icon then
			icon:TweenSize(
				ICON_HOVER_SCALE,
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quint,
				ICON_HOVER_TWEEN_TIME,
				true
			)
		end
	end)

	button.MouseLeave:Connect(function()
		if icon then
			icon:TweenSize(
				ICON_DEFAULT_SCALE,
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quint,
				ICON_LEAVE_TWEEN_TIME,
				true
			)
		end
	end)

	button.Destroying:Connect(function()
		boundButtons[button] = nil
	end)
end

local function isUnderTargetGui(instance: Instance, targetGuis: { ScreenGui }): boolean
	for _, gui in targetGuis do
		if instance:IsDescendantOf(gui) then
			return true
		end
	end
	return false
end

local function tryBindButton(instance: Instance, targetGuis: { ScreenGui }, sfx: SfxModule)
	if not instance:IsA("GuiButton") then
		return
	end
	if not isUnderTargetGui(instance, targetGuis) then
		return
	end
	if not CollectionService:HasTag(instance, UI_BUTTON_TAG) then
		return
	end
	bindButton(instance, sfx)
end

local function scanTargetGuis(targetGuis: { ScreenGui }, sfx: SfxModule)
	for _, gui in targetGuis do
		for _, descendant in gui:GetDescendants() do
			tryBindButton(descendant, targetGuis, sfx)
		end
	end
end

local LOBBY_SCREEN_GUI_NAME = "LobbyScreenGui"

type LobbyButtonHandler = (button: GuiButton) -> ()

local function onMissionClicked(_button: GuiButton)
	PopupManager.openPopup(PopupManager.PopupId.Mission)
end

local function onAchievementClicked(_button: GuiButton)
	PopupManager.openPopup(PopupManager.PopupId.Achievement)
end

local function onInventoryClicked(_button: GuiButton)
	PopupManager.openPopup(PopupManager.PopupId.Inventory)
end

local function onDailyClicked(_button: GuiButton)
	PopupManager.openPopup(PopupManager.PopupId.DailyReward)
end

local function onSettingClicked(_button: GuiButton)
	PopupManager.openPopup(PopupManager.PopupId.Setting)
end

local function onShopClicked(_button: GuiButton)
	PopupManager.openPopup(PopupManager.PopupId.Shop)
end

local function onBattlePassClicked(_button: GuiButton)
	PopupManager.openPopup(PopupManager.PopupId.BattlePass)
end

local function onGachaClicked(_button: GuiButton)
	PopupManager.openPopup(PopupManager.PopupId.Gacha)
end

local function onRelicClicked(_button: GuiButton)
	PopupManager.openPopup(PopupManager.PopupId.Relic)
end

local function onCostumeClicked(_button: GuiButton)
	PopupManager.openPopup(PopupManager.PopupId.Costume)
end

local LOBBY_BUTTON_HANDLERS: { [string]: LobbyButtonHandler } = {
	btnMission = onMissionClicked,
	btnQuest = onMissionClicked,
	btnAchievement = onAchievementClicked,
	btnInventory = onInventoryClicked,
	btnDaily = onDailyClicked,
	btnDailyReward = onDailyClicked,
	btnShop = onShopClicked,
	btnSetting = onSettingClicked,
	btnBattlePass = onBattlePassClicked,
	btnRelic = onRelicClicked,
	btnGacha = onGachaClicked,
	btnCostume = onCostumeClicked,
}

local boundLobbyClicks: { [GuiButton]: boolean } = {}

local function bindLobbyButtonClicks(lobbyGui: ScreenGui)
	for buttonName, handler in LOBBY_BUTTON_HANDLERS do
		local button = lobbyGui:FindFirstChild(buttonName, true)
		if not (button and button:IsA("GuiButton")) then
			continue
		end
		if boundLobbyClicks[button] then
			continue
		end
		boundLobbyClicks[button] = true

		button.Activated:Connect(function()
			handler(button)
		end)

		button.Destroying:Connect(function()
			boundLobbyClicks[button] = nil
		end)
	end
end

function LobbyUI.init()
	if initialized then
		return
	end
	initialized = true

	local sfx = resolveSfx()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui

	local targetGuis: { ScreenGui } = {}
	for _, name in TARGET_SCREEN_GUI_NAMES do
		table.insert(targetGuis, playerGui:WaitForChild(name) :: ScreenGui)
	end

	scanTargetGuis(targetGuis, sfx)

	for _, gui in targetGuis do
		if gui.Name == LOBBY_SCREEN_GUI_NAME then
			bindLobbyButtonClicks(gui)
			break
		end
	end

	CollectionService:GetInstanceAddedSignal(UI_BUTTON_TAG):Connect(function(instance: Instance)
		tryBindButton(instance, targetGuis, sfx)
	end)

	print("[LobbyUI] 초기화 완료")
end

return LobbyUI