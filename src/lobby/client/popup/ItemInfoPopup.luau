--[[
	ItemInfoPopup (lobby client)

	GUI 트리: PopupScreenGui.Content.ItemInfoPopup (CanvasGroup)
		Item.ItemIcon, ItemName, ItemDesc, BtnConfirm, BtnClose

	열기: ItemInfoPopup.open(itemType) — InventoryPopup 아이템 슬롯 클릭 시 호출 (InventoryPopup 위에 스택으로 표시)
	닫기: BtnConfirm / BtnClose

	아이콘: ReplicatedStorage.Client.Item.{ItemData.icon}
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local PopupManager = require(Shared.Managers.PopupManager)
local InventoryHelper = require(Shared.Helpers.InventoryHelper)
local StringHelper = require(Shared.Helpers.StringHelper)
local StringBinder = require(Shared.Helpers.StringBinder)

local ItemInfoPopup = {}

type ItemType = Types.ItemType

local POPUP_ROOT_NAME = "ItemInfoPopup"
local LOCALE = "kr"

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

local function applyImageLabelImageProperties(source: ImageLabel, target: ImageLabel)
	target.Image = source.Image
	target.ImageColor3 = source.ImageColor3
	target.ImageRectOffset = source.ImageRectOffset
	target.ImageRectSize = source.ImageRectSize
	target.ImageTransparency = source.ImageTransparency
	target.ResampleMode = source.ResampleMode
	target.ScaleType = source.ScaleType
end

local function findClientItemIcon(iconName: string): ImageLabel?
	local clientFolder = ReplicatedStorage:FindFirstChild("Client")
	if not clientFolder then
		return nil
	end
	local itemFolder = clientFolder:FindFirstChild("Item")
	if not itemFolder then
		return nil
	end
	local iconInst = itemFolder:FindFirstChild(iconName)
	if iconInst and iconInst:IsA("ImageLabel") then
		return iconInst :: ImageLabel
	end
	return nil
end

local function getItemInfoPopupRoot(): GuiObject?
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

local function applyItemInfo(rootGui: GuiObject, itemType: ItemType)
	local def = InventoryHelper.getItemDefinition(itemType)
	local iconName = if def then def.icon else InventoryHelper.getItemIconName(itemType)

	local itemFrame = rootGui:FindFirstChild("Item")
	local itemIconInst = itemFrame and itemFrame:FindFirstChild("ItemIcon")
	if itemIconInst and itemIconInst:IsA("ImageLabel") and iconName then
		local sourceIcon = findClientItemIcon(iconName)
		if sourceIcon then
			applyImageLabelImageProperties(sourceIcon, itemIconInst :: ImageLabel)
		else
			warn("[ItemInfoPopup] Client.Item." .. iconName, "없음 (", itemType, ")")
		end
	elseif not (itemIconInst and itemIconInst:IsA("ImageLabel")) then
		warn("[ItemInfoPopup] Item.ItemIcon (ImageLabel) 없음")
	end

	local itemNameInst = rootGui:FindFirstChild("ItemName")
	if itemNameInst and itemNameInst:IsA("TextLabel") then
		local titleKey = if def and def.title then def.title else (itemType .. "_Title")
		local itemNameLabel = itemNameInst :: TextLabel
		itemNameLabel.Text = StringHelper.get(titleKey, LOCALE)
	else
		warn("[ItemInfoPopup] ItemName (TextLabel) 없음")
	end

	local itemDescInst = rootGui:FindFirstChild("ItemDesc")
	if itemDescInst and itemDescInst:IsA("TextLabel") then
		local descKey = if def and def.desc then def.desc else (itemType .. "_Desc")
		local itemDescLabel = itemDescInst :: TextLabel
		itemDescLabel.Text = StringHelper.get(descKey, LOCALE)
	else
		warn("[ItemInfoPopup] ItemDesc (TextLabel) 없음")
	end
end

function ItemInfoPopup.open(itemType: ItemType)
	if activeSession then
		activeSession.close()
	end

	local normalizedItemType = Types.normalizeItemType(itemType)
	if not normalizedItemType then
		warn("[ItemInfoPopup] 잘못된 itemType:", itemType)
		return
	end

	local rootGui = getItemInfoPopupRoot()
	if not rootGui then
		warn("[ItemInfoPopup] Content.ItemInfoPopup 없음")
		return
	end
	StringBinder.applySubtreeOnce(rootGui)

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[ItemInfoPopup] Content 없음")
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
	end

	if not PopupManager.pushPopup({
		dim = false,
		blockInput = true,
		close = close,
		closeOthers = false,
		rootGui = rootGui,
	}) then
		contentGui.Active = prevContentActive
		rootGui.Active = prevRootActive
		return
	end

	rootGui.Visible = true
	applyItemInfo(rootGui, normalizedItemType)

	for _, buttonName in { "BtnConfirm", "BtnClose" } do
		local btnInst = rootGui:FindFirstChild(buttonName)
		if btnInst and btnInst:IsA("GuiButton") then
			local btn = btnInst :: GuiButton
			prepareClickableButton(btn)
			table.insert(connections, btn.Activated:Connect(close))
		else
			warn("[ItemInfoPopup]", buttonName, "없음")
		end
	end

	activeSession = { close = close }
end

function ItemInfoPopup.close()
	if activeSession then
		activeSession.close()
	end
end

function ItemInfoPopup.init()
	if initialized then
		return
	end
	initialized = true
	print("[ItemInfoPopup] 초기화 완료")
end

return ItemInfoPopup
