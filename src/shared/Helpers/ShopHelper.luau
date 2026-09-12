--[[
	ShopHelper (shared)

	마스터 데이터: DataManager.getShopDataRaw() (서버) / ReplicatedStorage.DataTable.ShopData (클라이언트)
	Roblox Developer Product 메타데이터: MarketplaceService:GetProductInfoAsync
	구매: 클라 PromptProductPurchase → 서버 ProcessReceipt → 재화 지급 → ShopPurchaseGranted
]]

local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DataManager = require(Shared.Managers.DataManager)
local BattlePassHelper = require(Shared.Helpers.BattlePassHelper)
local Types = require(Shared.Types)

local ShopHelper = {}

export type CurrencyType = Types.CurrencyType
export type ShopRewardEntry = Types.ShopRewardEntry
export type ShopProductDefinition = Types.ShopProductDefinition
export type ShopDataSource = Types.ShopDataSource

export type ShopProductInfo = {
	index: number,
	itemKey: string,
	productId: number,
	name: string,
	priceInRobux: number,
	iconImageAssetId: number,
	iconImage: string,
	isForSale: boolean,
	rewards: { ShopRewardEntry },
	description: string?,
}

export type ShopPurchaseGrantedPayload = {
	productId: number,
	rewards: { ShopRewardEntry },
}

ShopHelper.PURCHASE_GRANTED_EVENT_NAME = "ShopPurchaseGranted"

local PURCHASE_RECEIPT_STORE_NAME = "TitanStrike_PurchaseReceipts_v1"

local initialized = false
local preloadStarted = false
local runtime: ShopDataSource? = nil
local cacheByProductId: { [number]: ShopProductInfo } = {}
local cacheByItemKey: { [string]: ShopProductInfo } = {}
local purchaseReceiptStore = if RunService:IsServer()
	then DataStoreService:GetDataStore(PURCHASE_RECEIPT_STORE_NAME)
	else nil
local processedPurchaseCache: { [string]: boolean } = {}
local purchaseGrantedEvent: RemoteEvent? = nil
local externalProductGrantHandlers: { (player: Player, productId: number) -> boolean } = {}

local function normalizeProductIndex(raw: any): number?
	if typeof(raw) ~= "number" or raw ~= raw then
		return nil
	end
	local index = math.floor(raw)
	if index < 1 then
		return nil
	end
	return index
end

local function normalizeRewardAmount(raw: any): number?
	if typeof(raw) ~= "number" or raw ~= raw then
		return nil
	end
	local amount = math.floor(raw)
	if amount <= 0 then
		return nil
	end
	return amount
end

local function normalizeRewardEntry(raw: any): ShopRewardEntry?
	if typeof(raw) ~= "table" then
		return nil
	end
	if raw.rewardType == "BattlePassLevel" then
		local amount = normalizeRewardAmount(raw.amount)
		if not amount then
			return nil
		end
		return {
			rewardType = "BattlePassLevel",
			amount = amount,
		}
	end
	local currencyType = Types.normalizeCurrencyType(raw.currencyType)
	local amount = normalizeRewardAmount(raw.amount)
	if not currencyType or not amount then
		return nil
	end
	return {
		currencyType = currencyType,
		amount = amount,
	}
end

local function normalizeRewards(raw: any): { ShopRewardEntry }?
	if typeof(raw) ~= "table" then
		return nil
	end
	local rewards: { ShopRewardEntry } = {}
	for _, rewardRaw in raw do
		local entry = normalizeRewardEntry(rewardRaw)
		if not entry then
			return nil
		end
		table.insert(rewards, entry)
	end
	if #rewards == 0 then
		return nil
	end
	return rewards
end

local function cloneRewards(rewards: { ShopRewardEntry }): { ShopRewardEntry }
	local out: { ShopRewardEntry } = {}
	for _, reward in rewards do
		if reward.rewardType == "BattlePassLevel" then
			table.insert(out, {
				rewardType = "BattlePassLevel",
				amount = reward.amount,
			})
		else
			table.insert(out, {
				currencyType = reward.currencyType,
				amount = reward.amount,
			})
		end
	end
	return out
end

local function normalizeProductId(raw: any): number?
	if typeof(raw) ~= "number" or raw ~= raw then
		return nil
	end
	local productId = math.floor(raw)
	if productId <= 0 then
		return nil
	end
	return productId
end

local function normalizeItemKey(raw: any, index: number): string
	if typeof(raw) == "string" and raw ~= "" then
		return raw
	end
	return string.format("Item_%d", index)
end

local function normalizeProductDefinition(raw: any, tableKeyIndex: number?): ShopProductDefinition?
	if typeof(raw) ~= "table" then
		return nil
	end

	local indexFromRow = normalizeProductIndex(raw.index)
	local index = tableKeyIndex or indexFromRow
	if index == nil then
		return nil
	end
	if indexFromRow ~= nil and indexFromRow ~= index then
		warn(string.format("[ShopHelper] ShopData index 불일치 (key=%d, row.index=%d) — key 사용", index, indexFromRow))
	end

	local productId = normalizeProductId(raw.productId)
	local rewards = normalizeRewards(raw.rewards)
	if not productId or not rewards then
		return nil
	end

	return {
		index = index,
		itemKey = normalizeItemKey(raw.itemKey, index),
		productId = productId,
		rewards = rewards,
		hidden = raw.hidden == true,
	}
end

local function buildFallbackSource(): ShopDataSource
	return {
		products = {
			[1] = {
				index = 1,
				itemKey = "Item_1",
				productId = 3607138562,
				rewards = {
					{ currencyType = "Gem", amount = 500 },
				},
			},
			[2] = {
				index = 2,
				itemKey = "Item_2",
				productId = 3607138717,
				rewards = {
					{ currencyType = "Gem", amount = 1200 },
				},
			},
			[3] = {
				index = 3,
				itemKey = "Item_3",
				productId = 3607138820,
				rewards = {
					{ currencyType = "Gem", amount = 2500 },
				},
			},
			[4] = {
				index = 4,
				itemKey = "BattlePassJumpLevel",
				productId = 3609553930,
				rewards = {
					{ rewardType = "BattlePassLevel", amount = 5 },
				},
				hidden = true,
			},
		},
	}
end

local function normalizeSource(raw: any): ShopDataSource?
	if typeof(raw) ~= "table" or typeof(raw.products) ~= "table" then
		return nil
	end

	local products: { [number]: ShopProductDefinition } = {}
	for key, productRaw in raw.products do
		local productIndex = normalizeProductIndex(if typeof(key) == "number" then key else tonumber(key))
		if productIndex == nil then
			continue
		end
		local product = normalizeProductDefinition(productRaw, productIndex)
		if product then
			products[productIndex] = product
		end
	end

	if next(products) == nil then
		return nil
	end

	return { products = products }
end

local function loadShopDataRaw(): any?
	if RunService:IsServer() then
		local raw = DataManager.getShopDataRaw()
		if raw ~= nil then
			return raw
		end
		local ok, result = pcall(function()
			return require(ServerStorage:WaitForChild("DataTable"):WaitForChild("ShopData"))
		end)
		if ok then
			return result
		end
		return nil
	end

	local ok, result = pcall(function()
		return require(ReplicatedStorage:WaitForChild("DataTable"):WaitForChild("ShopData"))
	end)
	if ok then
		return result
	end
	return nil
end

local function getRuntime(): ShopDataSource
	if not runtime then
		local raw = loadShopDataRaw()
		local normalized = if raw ~= nil then normalizeSource(raw) else nil
		if normalized then
			runtime = normalized
			print(string.format("[ShopHelper] ShopData 로드 (%d개)", ShopHelper.getProductCount()))
		else
			runtime = buildFallbackSource()
			warn("[ShopHelper] ShopData 없음/형식 오류 — fallback 사용 (src/datatable/ShopData.luau)")
		end
	end
	return runtime :: ShopDataSource
end

local function buildIconImage(iconImageAssetId: number): string
	if typeof(iconImageAssetId) ~= "number" or iconImageAssetId <= 0 then
		return ""
	end
	return "rbxassetid://" .. tostring(math.floor(iconImageAssetId))
end

local function normalizePrice(raw: any): number
	if typeof(raw) ~= "number" or raw ~= raw then
		return 0
	end
	return math.max(0, math.floor(raw))
end

local function findProductDefinitionByProductId(productId: number): ShopProductDefinition?
	for _, product in getRuntime().products do
		if product.productId == productId then
			return product
		end
	end
	return nil
end

local function cacheProductInfo(info: ShopProductInfo)
	cacheByProductId[info.productId] = info
	cacheByItemKey[info.itemKey] = info
end

local function buildProductInfo(raw: any, product: ShopProductDefinition): ShopProductInfo
	local iconImageAssetId = if typeof(raw.IconImageAssetId) == "number" then math.floor(raw.IconImageAssetId) else 0
	local name = if typeof(raw.Name) == "string" then raw.Name else ""
	local description = if typeof(raw.Description) == "string" and raw.Description ~= "" then raw.Description else nil

	return {
		index = product.index,
		itemKey = product.itemKey,
		productId = product.productId,
		name = name,
		priceInRobux = normalizePrice(raw.PriceInRobux),
		iconImageAssetId = iconImageAssetId,
		iconImage = buildIconImage(iconImageAssetId),
		isForSale = raw.IsForSale == true,
		rewards = cloneRewards(product.rewards),
		description = description,
	}
end

local function formatRewardAmount(rewards: { ShopRewardEntry }): string
	local primary = rewards[1]
	if not primary then
		return "0"
	end
	return tostring(primary.amount)
end

function ShopHelper.applyProductToItemFrame(
	itemFrame: Instance,
	product: ShopProductDefinition,
	info: ShopProductInfo?
): boolean
	local applied = false

	local productImageInst = itemFrame:FindFirstChild("ProductImage")
	if productImageInst and productImageInst:IsA("ImageLabel") then
		local productImage = productImageInst :: ImageLabel
		if info and info.iconImage ~= "" then
			productImage.Image = info.iconImage
		end
		applied = true
	else
		warn("[ShopHelper]", itemFrame.Name, "ProductImage (ImageLabel) 없음")
	end

	local productNameInst = itemFrame:FindFirstChild("ProductName")
	if productNameInst and productNameInst:IsA("TextLabel") then
		local productName = productNameInst :: TextLabel
		if info and info.name ~= "" then
			productName.Text = info.name
		end
		applied = true
	else
		warn("[ShopHelper]", itemFrame.Name, "ProductName (TextLabel) 없음")
	end

	local rewardAmountInst = itemFrame:FindFirstChild("RewardAmount")
	if rewardAmountInst and rewardAmountInst:IsA("TextLabel") then
		local rewardAmount = rewardAmountInst :: TextLabel
		rewardAmount.Text = formatRewardAmount(product.rewards)
		applied = true
	else
		warn("[ShopHelper]", itemFrame.Name, "RewardAmount (TextLabel) 없음")
	end

	local btnBuy = itemFrame:FindFirstChild("BtnBuy")
	local robuxAmountInst = btnBuy and btnBuy:FindFirstChild("RobuxAmount")
	if robuxAmountInst and robuxAmountInst:IsA("TextLabel") then
		local robuxAmount = robuxAmountInst :: TextLabel
		if info then
			robuxAmount.Text = ShopHelper.formatRobuxPrice(info.priceInRobux)
		end
		applied = true
	else
		warn("[ShopHelper]", itemFrame.Name, "BtnBuy.RobuxAmount (TextLabel) 없음")
	end

	return applied
end

function ShopHelper.applyProductsToScrollingFrame(scrollingFrame: Instance): boolean
	local appliedAny = false
	for _, product in ShopHelper.getCatalog() do
		local itemFrame = scrollingFrame:FindFirstChild(product.itemKey)
		if not itemFrame then
			warn("[ShopHelper] ScrollingFrame.", product.itemKey, "없음")
			continue
		end

		local info = ShopHelper.fetchProductInfo(product.productId)
		if ShopHelper.applyProductToItemFrame(itemFrame, product, info) then
			appliedAny = true
		end
	end
	return appliedAny
end

function ShopHelper.getProductCount(): number
	local count = 0
	for _ in getRuntime().products do
		count += 1
	end
	return count
end

function ShopHelper.getProductIndices(): { number }
	local indices: { number } = {}
	for index in getRuntime().products do
		table.insert(indices, index)
	end
	table.sort(indices)
	return indices
end

function ShopHelper.getProduct(index: number): ShopProductDefinition?
	local productIndex = normalizeProductIndex(index)
	if productIndex == nil then
		return nil
	end
	local product = getRuntime().products[productIndex]
	if not product then
		return nil
	end
	return {
		index = product.index,
		itemKey = product.itemKey,
		productId = product.productId,
		rewards = cloneRewards(product.rewards),
	}
end

function ShopHelper.getProductByItemKey(itemKey: string): ShopProductDefinition?
	for _, product in getRuntime().products do
		if product.itemKey == itemKey then
			return {
				index = product.index,
				itemKey = product.itemKey,
				productId = product.productId,
				rewards = cloneRewards(product.rewards),
			}
		end
	end
	return nil
end

function ShopHelper.getProductByProductId(productId: number): ShopProductDefinition?
	local product = findProductDefinitionByProductId(productId)
	if not product then
		return nil
	end
	return {
		index = product.index,
		itemKey = product.itemKey,
		productId = product.productId,
		rewards = cloneRewards(product.rewards),
	}
end

function ShopHelper.getCatalog(): { ShopProductDefinition }
	local out: { ShopProductDefinition } = {}
	for _, index in ShopHelper.getProductIndices() do
		local raw = getRuntime().products[index]
		if raw and raw.hidden then
			continue
		end
		local product = ShopHelper.getProduct(index)
		if product then
			table.insert(out, product)
		end
	end
	return out
end

function ShopHelper.formatRobuxPrice(priceInRobux: number): string
	return tostring(math.max(0, math.floor(priceInRobux)))
end

function ShopHelper.getCachedProductInfo(productId: number): ShopProductInfo?
	return cacheByProductId[productId]
end

function ShopHelper.getCachedProductInfoByItemKey(itemKey: string): ShopProductInfo?
	return cacheByItemKey[itemKey]
end

function ShopHelper.fetchProductInfo(productId: number): ShopProductInfo?
	local product = findProductDefinitionByProductId(productId)
	if not product then
		warn("[ShopHelper] ShopData에 없는 productId:", productId)
		return nil
	end

	local cached = cacheByProductId[productId]
	if cached then
		return cached
	end

	local ok, raw = pcall(function()
		return MarketplaceService:GetProductInfoAsync(productId, Enum.InfoType.Product)
	end)
	if not ok or typeof(raw) ~= "table" then
		warn("[ShopHelper] GetProductInfoAsync 실패 productId=", productId, raw)
		return nil
	end

	local info = buildProductInfo(raw, product)
	cacheProductInfo(info)
	return info
end

function ShopHelper.fetchAllProducts(): { ShopProductInfo }
	local products: { ShopProductInfo } = {}
	for _, product in ShopHelper.getCatalog() do
		local info = ShopHelper.fetchProductInfo(product.productId)
		if info then
			table.insert(products, info)
		end
	end
	return products
end

local function normalizeReceiptPurchaseId(raw: any): string?
	if typeof(raw) == "string" and raw ~= "" then
		return raw
	end
	if typeof(raw) == "number" and raw == raw then
		return tostring(math.floor(raw))
	end
	return nil
end

local function normalizeReceiptUserId(raw: any): number?
	if typeof(raw) == "number" and raw == raw then
		return math.floor(raw)
	end
	if typeof(raw) == "string" then
		return tonumber(raw)
	end
	return nil
end

local function normalizeReceiptProductId(raw: any): number?
	local fromNumber = normalizeProductId(raw)
	if fromNumber then
		return fromNumber
	end
	if typeof(raw) == "string" then
		return normalizeProductId(tonumber(raw))
	end
	return nil
end

local function wasPurchaseProcessed(purchaseId: string): boolean
	if processedPurchaseCache[purchaseId] then
		return true
	end
	if not purchaseReceiptStore then
		return false
	end
	local ok, stored = pcall(function()
		return purchaseReceiptStore:GetAsync(purchaseId)
	end)
	if ok and stored == true then
		processedPurchaseCache[purchaseId] = true
		return true
	end
	return false
end

local function markPurchaseProcessed(purchaseId: string): boolean
	processedPurchaseCache[purchaseId] = true
	if not purchaseReceiptStore then
		return true
	end
	local ok = pcall(function()
		purchaseReceiptStore:SetAsync(purchaseId, true)
	end)
	if not ok then
		warn("[ShopHelper] PurchaseId 저장 실패:", purchaseId)
	end
	return ok
end

local function grantBattlePassLevels(player: Player, levelsToAdd: number): boolean
	local progress = DataManager.getBattlePassProgress(player)
	if not progress then
		return false
	end
	local maxLevel = BattlePassHelper.getMaxLevel()
	progress.level = math.min(progress.level + levelsToAdd, maxLevel)
	progress.xp = 0
	if not DataManager.setBattlePassProgress(player, progress) then
		return false
	end
	DataManager.savePlayerNow(player)
	return true
end

local function grantProductRewards(player: Player, productId: number): ({ ShopRewardEntry }?, string?)
	if not DataManager.waitUntilLoaded(player) then
		return nil, "데이터 미로드"
	end

	local product = findProductDefinitionByProductId(productId)
	if not product then
		return nil, "알 수 없는 상품"
	end

	local granted: { ShopRewardEntry } = {}
	for _, reward in product.rewards do
		if reward.rewardType == "BattlePassLevel" then
			local ok = grantBattlePassLevels(player, reward.amount)
			if not ok then
				warn(
					string.format(
						"[ShopHelper] 배틀패스 레벨 지급 실패 player=%s productId=%d amount=%d",
						player.Name,
						productId,
						reward.amount
					)
				)
				return nil, "보상 지급 실패"
			end
			table.insert(granted, {
				rewardType = "BattlePassLevel",
				amount = reward.amount,
			})
		else
			local ok = DataManager.addCurrency(player, reward.currencyType, reward.amount)
			if not ok then
				warn(
					string.format(
						"[ShopHelper] 재화 지급 실패 player=%s productId=%d %s=%d",
						player.Name,
						productId,
						reward.currencyType,
						reward.amount
					)
				)
				return nil, "재화 지급 실패"
			end
			table.insert(granted, {
				currencyType = reward.currencyType,
				amount = reward.amount,
			})
		end
	end

	return granted
end

local function normalizePurchaseGrantedPayload(raw: any): ShopPurchaseGrantedPayload?
	if typeof(raw) ~= "table" then
		return nil
	end
	local productId = normalizeProductId(raw.productId)
	if not productId then
		return nil
	end
	local rewards = normalizeRewards(raw.rewards)
	if not rewards then
		return nil
	end
	return {
		productId = productId,
		rewards = rewards,
	}
end

local function firePurchaseGranted(player: Player, productId: number, granted: { ShopRewardEntry })
	if not purchaseGrantedEvent then
		return
	end
	purchaseGrantedEvent:FireClient(player, {
		productId = productId,
		rewards = granted,
	})
end

local function processReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	if typeof(receiptInfo) ~= "table" then
		warn("[ShopHelper] ProcessReceipt receiptInfo가 table이 아님:", receiptInfo)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseId = normalizeReceiptPurchaseId(receiptInfo.PurchaseId)
	local productId = normalizeReceiptProductId(receiptInfo.ProductId)
	local playerId = normalizeReceiptUserId(receiptInfo.PlayerId)

	if purchaseId == nil or productId == nil or playerId == nil then
		warn(
			string.format(
				"[ShopHelper] ProcessReceipt 필드 누락 purchaseId=%s productId=%s playerId=%s raw=%s",
				tostring(receiptInfo.PurchaseId),
				tostring(receiptInfo.ProductId),
				tostring(receiptInfo.PlayerId),
				tostring(receiptInfo)
			)
		)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if wasPurchaseProcessed(purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local player = Players:GetPlayerByUserId(playerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- ShopData에 없는 productId는 외부 등록 핸들러(예: CostumeHelper의 Robux 코스튬)에게 위임.
	if not findProductDefinitionByProductId(productId) then
		for _, handler in externalProductGrantHandlers do
			local ok, handled = pcall(handler, player, productId)
			if ok and handled then
				if not markPurchaseProcessed(purchaseId) then
					warn("[ShopHelper] ProcessReceipt PurchaseId 저장 실패 — 재시도 예정:", purchaseId)
					return Enum.ProductPurchaseDecision.NotProcessedYet
				end
				print(
					string.format(
						"[ShopHelper] 외부 핸들러 구매 완료 player=%s productId=%d purchaseId=%s",
						player.Name,
						productId,
						purchaseId
					)
				)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
			if not ok then
				warn("[ShopHelper] 외부 핸들러 에러:", handled)
			end
		end
	end

	local granted, err = grantProductRewards(player, productId)
	if not granted then
		warn("[ShopHelper] ProcessReceipt 지급 실패:", player.Name, productId, err)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if not markPurchaseProcessed(purchaseId) then
		warn("[ShopHelper] ProcessReceipt PurchaseId 저장 실패 — 재시도 예정:", purchaseId)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	firePurchaseGranted(player, productId, granted)
	print(
		string.format(
			"[ShopHelper] 구매 완료 player=%s productId=%d purchaseId=%s",
			player.Name,
			productId,
			purchaseId
		)
	)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function bindPurchaseHandler()
	local existing = ReplicatedStorage:FindFirstChild(ShopHelper.PURCHASE_GRANTED_EVENT_NAME)
	local remote = if existing and existing:IsA("RemoteEvent")
		then existing
		else Instance.new("RemoteEvent")
	remote.Name = ShopHelper.PURCHASE_GRANTED_EVENT_NAME
	remote.Parent = ReplicatedStorage
	purchaseGrantedEvent = remote

	MarketplaceService.ProcessReceipt = processReceipt
end

function ShopHelper.init()
	if initialized then
		return
	end
	initialized = true
	getRuntime()

	if RunService:IsServer() then
		bindPurchaseHandler()
	end

	if RunService:IsClient() and not preloadStarted then
		preloadStarted = true
		task.spawn(function()
			local products = ShopHelper.fetchAllProducts()
			print(string.format("[ShopHelper] 상품 %d개 메타데이터 로드 완료", #products))
		end)
	end

	print("[ShopHelper] 초기화 완료")
end

function ShopHelper.getPurchaseGrantedEventName(): string
	return ShopHelper.PURCHASE_GRANTED_EVENT_NAME
end

function ShopHelper.normalizePurchaseGrantedPayload(raw: any): ShopPurchaseGrantedPayload?
	return normalizePurchaseGrantedPayload(raw)
end

--- MarketplaceService.ProcessReceipt는 게임당 하나만 등록 가능하며 ShopHelper가 이미 소유하고 있다.
--- ShopData에 없는 productId에 대해 다른 시스템(예: 코스튬 Robux 구매)이 지급 로직을 얹을 수 있게 하는 확장점.
--- handler(player, productId)는 자신이 처리할 상품이면 true를 반환해야 한다.
function ShopHelper.registerProductGrantHandler(handler: (player: Player, productId: number) -> boolean)
	table.insert(externalProductGrantHandlers, handler)
end

return ShopHelper
