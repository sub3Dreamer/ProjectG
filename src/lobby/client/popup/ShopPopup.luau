--[[
	ShopPopup (lobby client)

	GUI 트리: PopupScreenGui.Content.ShopPopup (CanvasGroup)
		Top.CloseButton
		Container.ScrollingFrame.Item_{1,2,3}
			ProductName — Developer Product 상품명
			RewardAmount — ShopData 보상 수량
			ProductImage — Developer Product 아이콘
			BtnBuy.RobuxAmount — Robux 가격 (클릭 시 Developer Product 구매)

	구매 흐름:
		BtnBuy → PromptProductPurchase
		서버 ProcessReceipt 재화 지급 → ShopPurchaseGranted (pending 저장)
		Roblox 구매 완료 팝업 확인(OK) → PromptProductPurchaseFinished
		→ 상단 재화 UI 갱신 + RewardPopup (Purchase)

	열기: LobbyScreenGui.btnShop 또는 PopupManager.openPopup(PopupManager.PopupId.Shop)
	닫기: Top.CloseButton
	딤 없음 (dim = false)
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)
local ShopHelper = require(Shared.Helpers.ShopHelper)
local StringBinder = require(Shared.Helpers.StringBinder)
local LobbyCurrencyUI = require(script.Parent.Parent.LobbyCurrencyUI)
local RewardPopup = require(script.Parent.RewardPopup)

local ShopPopup = {}

local POPUP_ROOT_NAME = "ShopPopup"

local initialized = false
local activeSession: { close: () -> () }? = nil
local isPurchasePromptOpen = false
local isAwaitingPromptClose = false
local purchasePromptResetToken = 0
local purchaseGrantedConnection: RBXScriptConnection? = nil
local _purchaseFinishedConnection: RBXScriptConnection? = nil

local pendingRewardCurrencyType: string? = nil
local pendingRewardAmount: number? = nil

local PURCHASE_PROMPT_TIMEOUT_SEC = 120

local function clearPurchasePromptState()
	isPurchasePromptOpen = false
	isAwaitingPromptClose = false
end

local function clearPendingReward()
	pendingRewardCurrencyType = nil
	pendingRewardAmount = nil
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

local function getShopPopupRoot(): GuiObject?
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

local function showPurchaseReward(currencyType: string, amount: number)
	task.defer(function()
		RewardPopup.open(RewardPopup.TitleType.Purchase, currencyType, amount)
	end)
end

local function tryShowPendingReward()
	if not pendingRewardCurrencyType or not pendingRewardAmount then
		return
	end
	if isAwaitingPromptClose then
		return
	end

	local currencyType = pendingRewardCurrencyType
	local amount = pendingRewardAmount
	clearPendingReward()

	LobbyCurrencyUI.unfreezeAndRefresh()
	showPurchaseReward(currencyType, amount)
end

local function schedulePurchasePromptReset(token: number)
	task.delay(PURCHASE_PROMPT_TIMEOUT_SEC, function()
		if purchasePromptResetToken ~= token then
			return
		end
		clearPurchasePromptState()
		LobbyCurrencyUI.unfreezeAndRefresh()
		tryShowPendingReward()
	end)
end

local function onPurchaseGranted(payload: any)
	local normalized = ShopHelper.normalizePurchaseGrantedPayload(payload)
	if not normalized then
		warn("[ShopPopup] ShopPurchaseGranted payload 형식 오류:", payload)
		return
	end

	local reward = normalized.rewards[1]
	if not reward then
		warn("[ShopPopup] ShopPurchaseGranted 보상 없음 productId=", normalized.productId)
		return
	end
	if not reward.currencyType then
		-- Shop 이외의 팝업(예: BattlePassPopup)이 트리거한 구매 — 여기서는 무시
		return
	end

	pendingRewardCurrencyType = reward.currencyType
	pendingRewardAmount = reward.amount
	tryShowPendingReward()
end

local function promptProductPurchase(productId: number)
	if isPurchasePromptOpen then
		return
	end

	isPurchasePromptOpen = true
	isAwaitingPromptClose = true
	clearPendingReward()
	LobbyCurrencyUI.freezeDisplay()
	purchasePromptResetToken += 1
	local token = purchasePromptResetToken
	schedulePurchasePromptReset(token)

	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(Players.LocalPlayer, productId)
	end)
	if not ok then
		warn("[ShopPopup] PromptProductPurchase 실패 productId=", productId, err)
		clearPurchasePromptState()
		LobbyCurrencyUI.unfreezeAndRefresh()
	end
end

local function refreshProductDisplay(rootGui: GuiObject)
	local container = rootGui:FindFirstChild("Container")
	local scroll = container and container:FindFirstChild("ScrollingFrame")
	if not scroll then
		warn("[ShopPopup] Container.ScrollingFrame 없음")
		return
	end

	ShopHelper.applyProductsToScrollingFrame(scroll)
end

local function bindBuyButtons(rootGui: GuiObject, connections: { RBXScriptConnection })
	local container = rootGui:FindFirstChild("Container")
	local scroll = container and container:FindFirstChild("ScrollingFrame")
	if not scroll then
		warn("[ShopPopup] Container.ScrollingFrame 없음")
		return
	end

	for _, entry in ShopHelper.getCatalog() do
		local item = scroll:FindFirstChild(entry.itemKey)
		local btnInst = item and item:FindFirstChild("BtnBuy")
		if btnInst and btnInst:IsA("GuiButton") then
			local btn = btnInst :: GuiButton
			local productId = entry.productId
			prepareClickableButton(btn)
			table.insert(connections, btn.Activated:Connect(function()
				promptProductPurchase(productId)
			end))
		else
			warn("[ShopPopup]", entry.itemKey, "BtnBuy 없음")
		end
	end
end

function ShopPopup.open(skipEntranceAnimation: boolean?)
	if activeSession then
		return
	end

	local rootGui = getShopPopupRoot()
	if not rootGui then
		warn("[ShopPopup] Content.ShopPopup 없음")
		return
	end
	StringBinder.applySubtreeOnce(rootGui)

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[ShopPopup] Content 없음")
		return
	end

	local top = rootGui:FindFirstChild("Top")
	local closeInst = top and top:FindFirstChild("CloseButton")
	if not (closeInst and closeInst:IsA("GuiButton")) then
		warn("[ShopPopup] Top.CloseButton 없음")
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
		playEntranceAnimation = not skipEntranceAnimation,
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
	refreshProductDisplay(rootGui)
	bindBuyButtons(rootGui, connections)

	activeSession = { close = close }
end

function ShopPopup.close()
	if activeSession then
		activeSession.close()
	end
end

local function bindPurchaseListeners()
	if purchaseGrantedConnection then
		return
	end

	local eventName = ShopHelper.getPurchaseGrantedEventName()
	local eventInst = ReplicatedStorage:WaitForChild(eventName)
	if not eventInst:IsA("RemoteEvent") then
		warn("[ShopPopup]", eventName, "RemoteEvent 없음")
		return
	end

	purchaseGrantedConnection = (eventInst :: RemoteEvent).OnClientEvent:Connect(onPurchaseGranted)
	-- 첫 인자는 Player가 아니라 userId (int64)
	_purchaseFinishedConnection = MarketplaceService.PromptProductPurchaseFinished:Connect(
		function(userId: number, _productId: number, wasPurchased: boolean)
			if userId ~= Players.LocalPlayer.UserId then
				return
			end

			isAwaitingPromptClose = false
			clearPurchasePromptState()

			if not wasPurchased then
				clearPendingReward()
				LobbyCurrencyUI.unfreezeAndRefresh()
				return
			end

			tryShowPendingReward()
		end
	)
end

function ShopPopup.init()
	if initialized then
		return
	end
	initialized = true
	ShopHelper.init()
	bindPurchaseListeners()
	print("[ShopPopup] 초기화 완료")
end

return ShopPopup
