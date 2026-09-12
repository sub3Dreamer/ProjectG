local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)

local BossIntroPopup = {}

local BOSS_DISPLAY_NAME_ATTR = "BossDisplayName"

local popupGui: GuiObject? = nil
local nameLabel: TextLabel? = nil
local wasPopupVisible = false
local wasNameVisible = false
local originalNameText = ""
local opened = false

local function resolveBossDisplayName(boss: Model): string
	local attr = boss:GetAttribute(BOSS_DISPLAY_NAME_ATTR)
	if typeof(attr) == "string" and attr ~= "" then
		return attr
	end
	return boss.Name
end

local function forceClose()
	if not opened then
		return
	end
	opened = false

	if nameLabel then
		nameLabel.Text = originalNameText
		nameLabel.Visible = wasNameVisible
	end
	if popupGui then
		popupGui.Visible = wasPopupVisible
	end

	popupGui = nil
	nameLabel = nil
	PopupManager.popPopup()
end

--- 입력 잠금과 동시에 호출. BossIntroPopup 표시, TxtBossName 숨김 (딤 없음).
function BossIntroPopup.begin(boss: Model): boolean
	if opened then
		forceClose()
	end

	if not PopupManager.getRootGui() then
		PopupManager.init()
	end

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[BossIntroPopup] Content 없음 (PopupScreenGui / PopupManager.init 확인)")
		return false
	end

	local popup = content:FindFirstChild("BossIntroPopup")
	if not (popup and popup:IsA("GuiObject")) then
		warn("[BossIntroPopup] Content.BossIntroPopup 을 찾을 수 없습니다")
		return false
	end

	local txtBossName = popup:FindFirstChild("TxtBossName", true)
	if not (txtBossName and txtBossName:IsA("TextLabel")) then
		warn("[BossIntroPopup] BossIntroPopup.TxtBossName (TextLabel) 을 찾을 수 없습니다")
		return false
	end

	local label = txtBossName :: TextLabel
	local gui = popup :: GuiObject

	popupGui = gui
	nameLabel = label
	wasPopupVisible = gui.Visible
	wasNameVisible = label.Visible
	originalNameText = label.Text
	opened = true

	if not PopupManager.pushPopup({ dim = false, blockInput = false, rootGui = gui }) then
		opened = false
		popupGui = nil
		nameLabel = nil
		return false
	end

	-- label.Text = resolveBossDisplayName(boss)
	label.Visible = false
	gui.Visible = true

	return true
end

--- 보스 포커싱(줌인 완료) 시점에 TxtBossName 표시.
function BossIntroPopup.showBossName()
	if not opened or not nameLabel then
		return
	end
	nameLabel.Visible = true
end

function BossIntroPopup.close()
	forceClose()
end

function BossIntroPopup.isOpen(): boolean
	return opened
end

return BossIntroPopup
