--[[
	InventoryPopup (lobby client)

	GUI 트리: PopupScreenGui.Content.InventoryPopup (CanvasGroup)
		Inventory
			Top.CloseButton
			TabGroup.BtnItem
			Container.CanvasGroup.ScrollingContainer
				Item (템플릿) — ItemIcon, ItemCnt, Btn
		Custom.ColorWindow — Viperdune Color Picker UI

	열기: LobbyScreenGui.LeftButtons.btnInventory
	닫기: Inventory.Top.CloseButton
	기본: Container Visible = true

	아이콘: ReplicatedStorage.Client.Item.{ItemData.icon}
	목록: GetInventorySnapshot (보유량 > 0). ItemPool은 모듈 레벨에서 용량만 확장.
	슬롯 Btn → ItemInfoPopup.open(itemType) (별도 팝업, InventoryPopup 위에 스택으로 표시)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local PopupManager = require(Shared.Managers.PopupManager)
local InventoryHelper = require(Shared.Helpers.InventoryHelper)
local StringBinder = require(Shared.Helpers.StringBinder)
local InventoryColorPicker = require(script.Parent.InventoryColorPicker)
local ItemInfoPopup = require(script.Parent.ItemInfoPopup)

local InventoryPopup = {}

type InventoryItemEntry = InventoryHelper.InventoryItemEntry
type InventorySnapshot = InventoryHelper.InventorySnapshot
type ItemType = Types.ItemType

local POPUP_ROOT_NAME = "InventoryPopup"
local INVENTORY_PANEL_NAME = "Inventory"
local CONTAINER_NAME = "Container"
local ITEM_TAB_BUTTON_NAME = "BtnItem"
local GET_SNAPSHOT_REMOTE_NAME = InventoryHelper.GET_SNAPSHOT_REMOTE_NAME

local initialized = false
local activeSession: {
	close: () -> (),
	colorPicker: InventoryColorPicker.Session?,
}? = nil

local snapshotRemote: RemoteFunction? = nil
local itemPool: { GuiObject } = {}
local itemTemplate: GuiObject? = nil
local scrollingContainer: GuiObject? = nil
local slotBoundItemType: { [GuiObject]: ItemType } = {}

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

local function getSnapshotRemote(): RemoteFunction
	if snapshotRemote then
		return snapshotRemote
	end
	local remote = ReplicatedStorage:WaitForChild(GET_SNAPSHOT_REMOTE_NAME)
	assert(remote:IsA("RemoteFunction"), "[InventoryPopup] GetInventorySnapshot RemoteFunction 없음")
	local typedRemote = remote :: RemoteFunction
	snapshotRemote = typedRemote
	return typedRemote
end

local function fetchInventorySnapshot(): InventorySnapshot?
	local ok, result = pcall(function()
		return getSnapshotRemote():InvokeServer()
	end)
	if not ok then
		warn("[InventoryPopup] GetInventorySnapshot 실패:", result)
		return nil
	end
	if typeof(result) ~= "table" or typeof((result :: any).items) ~= "table" then
		warn("[InventoryPopup] GetInventorySnapshot 응답 형식 오류")
		return nil
	end
	return result :: InventorySnapshot
end

local function getInventoryPopupRoot(): GuiObject?
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

local function getInventoryPanel(rootGui: GuiObject): GuiObject?
	local panel = rootGui:FindFirstChild(INVENTORY_PANEL_NAME)
	if panel and panel:IsA("GuiObject") then
		return panel :: GuiObject
	end
	return nil
end

local function getItemContainer(inventoryPanel: GuiObject): GuiObject?
	local container = inventoryPanel:FindFirstChild(CONTAINER_NAME)
	if container and container:IsA("GuiObject") then
		return container :: GuiObject
	end
	return nil
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

local function resolveItemListUi(inventoryPanel: GuiObject): boolean
	if itemTemplate and scrollingContainer and scrollingContainer.Parent then
		return true
	end

	local container = getItemContainer(inventoryPanel)
	if not container then
		warn("[InventoryPopup] Inventory." .. CONTAINER_NAME, "없음")
		return false
	end

	local canvasGroup = container:FindFirstChild("CanvasGroup")
	if not canvasGroup then
		warn("[InventoryPopup] Inventory.Container.CanvasGroup 없음")
		return false
	end

	local scrollingInst = canvasGroup:FindFirstChild("ScrollingContainer")
	if not (scrollingInst and scrollingInst:IsA("GuiObject")) then
		warn("[InventoryPopup] Inventory.Container.CanvasGroup.ScrollingContainer 없음")
		return false
	end

	local templateInst = scrollingInst:FindFirstChild("Item")
	if not (templateInst and templateInst:IsA("GuiObject")) then
		warn("[InventoryPopup] ScrollingContainer.Item 템플릿 없음")
		return false
	end

	local template = templateInst :: GuiObject
	template.Visible = false
	itemTemplate = template
	scrollingContainer = scrollingInst :: GuiObject
	return true
end

local function wireSlotButton(slot: GuiObject)
	local btnInst = slot:FindFirstChild("Btn")
	if not (btnInst and btnInst:IsA("GuiButton")) then
		warn("[InventoryPopup] Item.Btn 없음")
		return
	end
	local btn = btnInst :: GuiButton
	prepareClickableButton(btn)
	btn.Activated:Connect(function()
		local boundType = slotBoundItemType[slot]
		if not boundType then
			return
		end
		ItemInfoPopup.open(boundType)
	end)
end

local function ensureItemPoolCapacity(needed: number): boolean
	if not itemTemplate or not scrollingContainer then
		return false
	end

	while #itemPool < needed do
		local index = #itemPool + 1
		local cloneInst = itemTemplate:Clone()
		cloneInst.Name = "Item_" .. tostring(index)
		cloneInst.LayoutOrder = index
		cloneInst.Visible = false
		cloneInst.Parent = scrollingContainer
		wireSlotButton(cloneInst)
		table.insert(itemPool, cloneInst)
	end

	return true
end

local function bindItemSlot(slot: GuiObject, entry: InventoryItemEntry)
	slotBoundItemType[slot] = entry.itemType

	local iconName = InventoryHelper.getItemIconName(entry.itemType)
	local itemIconInst = slot:FindFirstChild("ItemIcon")
	if itemIconInst and itemIconInst:IsA("ImageLabel") and iconName then
		local sourceIcon = findClientItemIcon(iconName)
		if sourceIcon then
			applyImageLabelImageProperties(sourceIcon, itemIconInst :: ImageLabel)
		else
			warn("[InventoryPopup] Client.Item." .. iconName, "없음 (", entry.itemType, ")")
		end
	elseif not (itemIconInst and itemIconInst:IsA("ImageLabel")) then
		warn("[InventoryPopup] Item.ItemIcon (ImageLabel) 없음")
	end

	local itemCntInst = slot:FindFirstChild("ItemCnt")
	if itemCntInst and itemCntInst:IsA("TextLabel") then
		(itemCntInst :: TextLabel).Text = tostring(math.floor(entry.count))
	else
		warn("[InventoryPopup] Item.ItemCnt (TextLabel) 없음")
	end

	local btnInst = slot:FindFirstChild("Btn")
	if btnInst and btnInst:IsA("GuiButton") then
		prepareClickableButton(btnInst :: GuiButton)
	end
end

local function refreshItemList(entries: { InventoryItemEntry })
	if not ensureItemPoolCapacity(#entries) then
		return
	end

	for index, slot in ipairs(itemPool) do
		local entry = entries[index]
		if entry then
			bindItemSlot(slot, entry)
			slot.Visible = true
			slot.LayoutOrder = index
		else
			slotBoundItemType[slot] = nil
			slot.Visible = false
		end
	end
end

local function showItemContainer(inventoryPanel: GuiObject)
	local container = getItemContainer(inventoryPanel)
	if container then
		container.Visible = true
	else
		warn("[InventoryPopup] Inventory." .. CONTAINER_NAME, "없음")
	end
end

local function bindItemTabButton(inventoryPanel: GuiObject, connections: { RBXScriptConnection })
	local tabGroup = inventoryPanel:FindFirstChild("TabGroup")
	if not tabGroup then
		warn("[InventoryPopup] Inventory.TabGroup 없음")
		return
	end

	local btnInst = tabGroup:FindFirstChild(ITEM_TAB_BUTTON_NAME)
	if btnInst and btnInst:IsA("GuiButton") then
		local btn = btnInst :: GuiButton
		prepareClickableButton(btn)
		table.insert(connections, btn.Activated:Connect(function()
			showItemContainer(inventoryPanel)
		end))
	else
		warn("[InventoryPopup] Inventory.TabGroup." .. ITEM_TAB_BUTTON_NAME, "없음")
	end
end

function InventoryPopup.open()
	if activeSession then
		return
	end

	local rootGui = getInventoryPopupRoot()
	if not rootGui then
		warn("[InventoryPopup] Content.InventoryPopup 없음")
		return
	end
	StringBinder.applySubtreeOnce(rootGui)

	local inventoryPanel = getInventoryPanel(rootGui)
	if not inventoryPanel then
		warn("[InventoryPopup] Inventory 패널 없음")
		return
	end

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[InventoryPopup] Content 없음")
		return
	end

	local top = inventoryPanel:FindFirstChild("Top")
	local closeInst = top and top:FindFirstChild("CloseButton")
	if not (closeInst and closeInst:IsA("GuiButton")) then
		warn("[InventoryPopup] Inventory.Top.CloseButton 없음")
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
	local colorPickerSession: InventoryColorPicker.Session? = nil

	local function close()
		if closed then
			return
		end
		closed = true
		ItemInfoPopup.close()
		if colorPickerSession then
			colorPickerSession.destroy()
			colorPickerSession = nil
		end
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

	ItemInfoPopup.close()
	showItemContainer(inventoryPanel)

	if resolveItemListUi(inventoryPanel) then
		local snapshot = fetchInventorySnapshot()
		local entries: { InventoryItemEntry } = {}
		if snapshot then
			for _, row in snapshot.items do
				local itemType = Types.normalizeItemType(row.itemType)
				local count = if typeof(row.count) == "number" then math.floor(row.count) else 0
				if itemType and count > 0 then
					table.insert(entries, {
						itemType = itemType,
						count = count,
					})
				end
			end
		end
		refreshItemList(entries)
	end

	rootGui.Visible = true
	if pushOptions.playEntranceAnimation then
		PopupManager.playBounceEntrance(rootGui)
	end

	prepareClickableButton(closeBtn)
	table.insert(connections, closeBtn.Activated:Connect(close))
	bindItemTabButton(inventoryPanel, connections)

	local customFrame = rootGui:FindFirstChild("Custom")
	local colorWindow = customFrame and customFrame:FindFirstChild("ColorWindow")
	if colorWindow and colorWindow:IsA("Frame") then
		colorPickerSession = InventoryColorPicker.bind(colorWindow, {})
	else
		warn("[InventoryPopup] Custom.ColorWindow 없음 — ColorPicker 미연결")
	end

	activeSession = {
		close = close,
		colorPicker = colorPickerSession,
	}
end

function InventoryPopup.close()
	if activeSession then
		activeSession.close()
	end
end

function InventoryPopup.init()
	if initialized then
		return
	end
	initialized = true
	print("[InventoryPopup] 초기화 완료")
end

return InventoryPopup
