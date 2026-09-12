--[[
	GachaPopup (lobby client)

	GUI 트리: PopupScreenGui.Content.GachaPopup (Frame)
		Container.Items — Normal, Special (각 Buttons.BtnSummon_1/10, Title, Desc, Chest)
			BtnSummon_* 하위 Icon(ImageLabel), TxtAmount(TextLabel)
				— Normal: RelicNormalKey, Special: RelicSpecialKey 보유량이 소환에 필요한 개수(1/10) 이상이면
				  Icon = 열쇠 아이콘, TxtAmount = 보유 열쇠 개수
				  부족하면 기존처럼 Icon = 재화 아이콘, TxtAmount = 비용
		Top.CloseButton

	뽑기 버튼 → 서버 SummonRelics (열쇠 보유량 충분하면 열쇠 우선 소모, 아니면 재화 차감) → GachaPopup 닫기
		→ RelicSummonPopup 연출 → GachaPopup 재오픈
	재화/열쇠 모두 부족 시 무반응.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local PopupManager = require(Shared.Managers.PopupManager)
local RelicHelper = require(Shared.Helpers.RelicHelper)
local InventoryHelper = require(Shared.Helpers.InventoryHelper)
local StringBinder = require(Shared.Helpers.StringBinder)
local RelicSummonPopup = require(script.Parent.RelicSummonPopup)
local RelicClient = require(script.Parent.Parent.RelicClient)

local GachaPopup = {}

local POPUP_ROOT_NAME = "GachaPopup"
local SUMMON_REMOTE_NAME = "SummonRelics"
local CURRENCY_FOLDER_PATH = { "Client", "Currency" }

type SummonPool = "Normal" | "Special"
type SummonCostEntry = Types.SummonCostEntry

local initialized = false
local activeSession: { close: () -> () }? = nil
local summonRemote: RemoteFunction? = nil
local summoning = false
local currencyIcons: { [string]: ImageLabel? }? = nil

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

local function getGachaPopupRoot(): GuiObject?
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

local function resolveCurrencyIcons(): { [string]: ImageLabel? }?
	if currencyIcons then
		return currencyIcons
	end

	local folder: Instance = ReplicatedStorage
	for _, name in CURRENCY_FOLDER_PATH do
		local child = folder:FindFirstChild(name)
		if not child then
			warn("[GachaPopup] ReplicatedStorage." .. table.concat(CURRENCY_FOLDER_PATH, ".") .. " 없음")
			return nil
		end
		folder = child
	end

	local icons: { [string]: ImageLabel? } = {}
	for _, currencyType in { "Gem", "Gold", "BattlePassPoint" } do
		local iconInst = folder:FindFirstChild(currencyType)
		local icon = if iconInst and iconInst:IsA("ImageLabel") then iconInst :: ImageLabel else nil
		if not icon then
			warn("[GachaPopup] Client.Currency." .. currencyType .. " (ImageLabel) 없음")
		end
		icons[currencyType] = icon
	end

	currencyIcons = icons
	return currencyIcons
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

local function applySummonButtonUi(
	button: GuiButton,
	cost: SummonCostEntry,
	count: number,
	keyItemType: Types.ItemType?,
	ownedKeyCount: number,
	icons: { [string]: ImageLabel? }
)
	local useKey = keyItemType ~= nil and ownedKeyCount >= count

	local iconInst = button:FindFirstChild("Icon")
	if iconInst and iconInst:IsA("ImageLabel") then
		local sourceIcon: ImageLabel? = nil
		if useKey then
			local iconName = InventoryHelper.getItemIconName(keyItemType :: Types.ItemType)
			sourceIcon = if iconName then findClientItemIcon(iconName) else nil
		else
			sourceIcon = icons[cost.currencyType]
		end
		if sourceIcon then
			applyImageLabelImageProperties(sourceIcon, iconInst :: ImageLabel)
		end
	end

	local txtAmountInst = button:FindFirstChild("TxtAmount")
	if txtAmountInst and txtAmountInst:IsA("TextLabel") then
		local txtAmount = txtAmountInst :: TextLabel
		txtAmount.Text = tostring(math.floor(if useKey then ownedKeyCount else cost.amount))
	end
end

local function applySummonSectionUi(
	section: Instance,
	pool: SummonPool,
	ownedKeyCount: number,
	icons: { [string]: ImageLabel? }
)
	local buttons = section:FindFirstChild("Buttons")
	if not buttons then
		return
	end

	local keyItemType = RelicHelper.getSummonKeyItemType(pool)

	for _, count in { 1, 10 } do
		local btn = buttons:FindFirstChild("BtnSummon_" .. tostring(count))
		local cost = RelicHelper.getSummonCost(pool, count)
		if btn and btn:IsA("GuiButton") and cost then
			applySummonButtonUi(btn :: GuiButton, cost, count, keyItemType, ownedKeyCount, icons)
		end
	end
end

local function getSummonRemote(): RemoteFunction
	if summonRemote then
		return summonRemote
	end
	local remote = ReplicatedStorage:WaitForChild(SUMMON_REMOTE_NAME)
	assert(remote:IsA("RemoteFunction"), "[GachaPopup] SummonRelics RemoteFunction 없음")
	local typedRemote = remote :: RemoteFunction
	summonRemote = typedRemote
	return typedRemote
end

local function requestSummon(pool: SummonPool, count: number): { any }?
	local ok, results = pcall(function()
		return getSummonRemote():InvokeServer(pool, count)
	end)
	if not ok then
		warn("[GachaPopup] SummonRelics 호출 실패:", results)
		return nil
	end
	if typeof(results) ~= "table" or #results == 0 then
		return nil
	end
	return results
end

local function beginSummon(pool: SummonPool, count: number)
	if summoning then
		return
	end

	local results = requestSummon(pool, count)
	if not results then
		return
	end

	summoning = true
	GachaPopup.close()
	RelicSummonPopup.play(results, function()
		summoning = false
		RelicClient.refreshNotification()
		GachaPopup.open()
	end)
end

local function wireSummonSection(
	rootGui: GuiObject,
	sectionName: string,
	pool: SummonPool,
	ownedKeyCount: number,
	icons: { [string]: ImageLabel? },
	connections: { RBXScriptConnection }
)
	local container = rootGui:FindFirstChild("Container")
	local items = container and container:FindFirstChild("Items")
	local section = items and items:FindFirstChild(sectionName)
	local buttons = section and section:FindFirstChild("Buttons")
	if not buttons then
		warn("[GachaPopup] Container.Items." .. sectionName .. ".Buttons 없음")
		return
	end

	applySummonSectionUi(section :: Instance, pool, ownedKeyCount, icons)

	local btn1 = buttons:FindFirstChild("BtnSummon_1")
	local btn10 = buttons:FindFirstChild("BtnSummon_10")

	if btn1 and btn1:IsA("GuiButton") then
		prepareClickableButton(btn1)
		table.insert(connections, (btn1 :: GuiButton).Activated:Connect(function()
			beginSummon(pool, 1)
		end))
	end

	if btn10 and btn10:IsA("GuiButton") then
		prepareClickableButton(btn10)
		table.insert(connections, (btn10 :: GuiButton).Activated:Connect(function()
			beginSummon(pool, 10)
		end))
	end
end

function GachaPopup.open()
	if activeSession then
		return
	end

	local rootGui = getGachaPopupRoot()
	if not rootGui then
		warn("[GachaPopup] Content.GachaPopup 없음")
		return
	end
	StringBinder.applySubtreeOnce(rootGui)

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[GachaPopup] Content 없음")
		return
	end

	local top = rootGui:FindFirstChild("Top")
	local closeInst = top and top:FindFirstChild("CloseButton")
	if not (closeInst and closeInst:IsA("GuiButton")) then
		warn("[GachaPopup] Top.CloseButton 없음")
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

	prepareClickableButton(closeBtn)
	table.insert(connections, closeBtn.Activated:Connect(close))

	local icons = resolveCurrencyIcons() or {}
	local inventorySnapshot = InventoryHelper.fetchSnapshot()
	local normalKeyCount = InventoryHelper.getItemCountFromSnapshot(inventorySnapshot, "RelicNormalKey")
	local specialKeyCount = InventoryHelper.getItemCountFromSnapshot(inventorySnapshot, "RelicSpecialKey")

	wireSummonSection(rootGui, "Normal", "Normal", normalKeyCount, icons, connections)
	wireSummonSection(rootGui, "Special", "Special", specialKeyCount, icons, connections)

	activeSession = { close = close }
end

function GachaPopup.close()
	if activeSession then
		activeSession.close()
	end
end

function GachaPopup.init()
	if initialized then
		return
	end
	initialized = true
	print("[GachaPopup] 초기화 완료")
end

return GachaPopup
