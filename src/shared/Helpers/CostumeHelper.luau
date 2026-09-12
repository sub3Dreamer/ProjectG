--[[
	CostumeHelper (shared)

	마스터 데이터: ServerStorage.DataTable.CostumeData (서버) / ReplicatedStorage.DataTable.CostumeData (클라이언트)
	Robux 가격: MarketplaceService:GetProductInfoAsync(productId, Enum.InfoType.Product) (productId별 캐싱)
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local DataManager = require(Shared.Managers.DataManager)
local ShopHelper = require(Shared.Helpers.ShopHelper)

local CostumeHelper = {}

export type CostumeCostType = Types.CostumeCostType
export type CostumeDefinition = Types.CostumeDefinition
export type CostumeDataSource = Types.CostumeDataSource

export type AppearanceSnapshot = {
	accessories: { Accessory },
	shirt: Shirt?,
	pants: Pants?,
	bodyColors: BodyColors?,
	characterMeshes: { CharacterMesh },
	faceDecal: Decal?,
}

local COSTUME_DATA_MODULE_NAME = "CostumeData"
local COSTUME_FOLDER_NAME = "Costume"
local FACE_DECAL_NAME = "face"
local PREVIEW_REMOTE_NAME = "CostumePreviewRequest"
local EQUIP_REMOTE_NAME = "CostumeEquipRequest"
local OWNERSHIP_REMOTE_NAME = "GetCostumeOwnership"
local PURCHASE_REQUEST_REMOTE_NAME = "CostumePurchaseRequest"
local PURCHASE_GRANTED_EVENT_NAME = "CostumePurchaseGranted"

local runtime: CostumeDataSource? = nil
local robuxPriceByProductId: { [number]: number } = {}
local initialized = false

type PreviewState = {
	character: Model,
	snapshot: AppearanceSnapshot,
}
local previewStateByPlayer: { [Player]: PreviewState } = {}

--- 캐릭터별 "장착 전 원래 외형" 스냅샷. 장착 코스튬을 처음 적용하기 직전(스폰 직후)에 한 번만 캡처해둬야
--- 나중에 장착 해제 시 복원할 수 있다 (clearAppearance가 원본 파츠를 destroy하듯 지워버리므로).
local originalAppearanceByCharacter: { [Model]: AppearanceSnapshot } = {}

local function normalizeCostAmount(raw: any): number?
	if typeof(raw) ~= "number" or raw ~= raw then
		return nil
	end
	local amount = math.floor(raw)
	if amount <= 0 then
		return nil
	end
	return amount
end

local function normalizeProductId(raw: any): number?
	local asNumber = if typeof(raw) == "number" then raw elseif typeof(raw) == "string" then tonumber(raw) else nil
	if asNumber == nil or asNumber ~= asNumber then
		return nil
	end
	local productId = math.floor(asNumber)
	if productId <= 0 then
		return nil
	end
	return productId
end

local function normalizeCostumeDefinition(raw: any, expectedId: string?): CostumeDefinition?
	if typeof(raw) ~= "table" then
		return nil
	end

	local id = if typeof(raw.id) == "string" and raw.id ~= "" then raw.id else expectedId
	if typeof(id) ~= "string" or id == "" then
		return nil
	end
	if typeof(raw.iconAssetId) ~= "string" or raw.iconAssetId == "" then
		return nil
	end
	local costType = Types.normalizeCostumeCostType(raw.costType)
	if not costType then
		return nil
	end

	local costAmount: number? = nil
	local productId: number? = nil
	if costType == "Robux" then
		productId = normalizeProductId(raw.productId)
		if not productId then
			return nil
		end
	else
		costAmount = normalizeCostAmount(raw.costAmount)
		if not costAmount then
			return nil
		end
	end

	return {
		id = id,
		modelName = if typeof(raw.modelName) == "string" then raw.modelName else "",
		iconAssetId = raw.iconAssetId,
		costType = costType,
		costAmount = costAmount,
		productId = productId,
	}
end

local function normalizeSource(raw: any): CostumeDataSource?
	if typeof(raw) ~= "table" or typeof(raw.costumes) ~= "table" then
		return nil
	end

	local costumes: { [string]: CostumeDefinition } = {}
	for key, row in raw.costumes do
		local expectedId = if typeof(key) == "string" then key else nil
		local def = normalizeCostumeDefinition(row, expectedId)
		if def then
			costumes[def.id] = def
		end
	end
	if next(costumes) == nil then
		return nil
	end

	return { costumes = costumes }
end

local function loadCostumeDataRaw(): any?
	if RunService:IsServer() then
		local ok, result = pcall(function()
			return require(ServerStorage:WaitForChild("DataTable"):WaitForChild(COSTUME_DATA_MODULE_NAME))
		end)
		if ok then
			return result
		end
		return nil
	end

	local ok, result = pcall(function()
		return require(ReplicatedStorage:WaitForChild("DataTable"):WaitForChild(COSTUME_DATA_MODULE_NAME))
	end)
	if ok then
		return result
	end
	return nil
end

local function getRuntime(): CostumeDataSource
	if not runtime then
		local raw = loadCostumeDataRaw()
		local normalized = if raw ~= nil then normalizeSource(raw) else nil
		if normalized then
			runtime = normalized
		else
			runtime = { costumes = {} }
			warn("[CostumeHelper] CostumeData 없음/형식 오류 (src/datatable/CostumeData.luau)")
		end
	end
	return runtime :: CostumeDataSource
end

function CostumeHelper.getCostumeIds(): { string }
	local ids: { string } = {}
	for id in getRuntime().costumes do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

function CostumeHelper.getCostume(id: string): CostumeDefinition?
	local def = getRuntime().costumes[id]
	if not def then
		return nil
	end
	return {
		id = def.id,
		modelName = def.modelName,
		iconAssetId = def.iconAssetId,
		costType = def.costType,
		costAmount = def.costAmount,
		productId = def.productId,
	}
end

function CostumeHelper.fetchRobuxPrice(productId: number): number?
	local cached = robuxPriceByProductId[productId]
	if cached then
		return cached
	end

	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfoAsync(productId, Enum.InfoType.Product)
	end)
	if not ok or typeof(info) ~= "table" or typeof(info.PriceInRobux) ~= "number" then
		warn("[CostumeHelper] GetProductInfoAsync 실패 productId=", productId, info)
		return nil
	end

	local price = math.max(0, math.floor(info.PriceInRobux))
	robuxPriceByProductId[productId] = price
	return price
end

--[[
	서버 전용: 코스튬 미리보기를 실제 캐릭터에 적용/복원.

	Humanoid:AddAccessory()를 LocalScript에서 호출하면 엔진이
	"Accessory is already being worn by another character"로 거부하고,
	레이어드 클로딩(Cage/Wrap 기반 체형 맞춤 변형)도 클라이언트에서는 재현할 수 없다.
	그래서 미리보기 자체를 서버에서 처리하고 클라이언트는 요청만 보낸다
	(CostumePopup 미리보기 특성상 다른 플레이어에게도 보이는 것은 의도된 트레이드오프).
]]

local function getCostumeFolder(): Folder?
	local folder = ReplicatedStorage:FindFirstChild(COSTUME_FOLDER_NAME)
	if folder then
		return folder :: Folder
	end
	warn("[CostumeHelper] ReplicatedStorage." .. COSTUME_FOLDER_NAME .. " 없음")
	return nil
end

local function findFaceDecal(head: Instance?): Decal?
	if not head then
		return nil
	end
	local face = head:FindFirstChild(FACE_DECAL_NAME)
	if face and face:IsA("Decal") then
		return face :: Decal
	end
	return nil
end

local function snapshotAppearance(character: Model): AppearanceSnapshot
	local snapshot: AppearanceSnapshot = {
		accessories = {},
		shirt = nil,
		pants = nil,
		bodyColors = nil,
		characterMeshes = {},
		faceDecal = nil,
	}

	for _, child in character:GetChildren() do
		if child:IsA("Accessory") then
			table.insert(snapshot.accessories, child:Clone())
		elseif child:IsA("Shirt") then
			snapshot.shirt = child:Clone()
		elseif child:IsA("Pants") then
			snapshot.pants = child:Clone()
		elseif child:IsA("BodyColors") then
			snapshot.bodyColors = child:Clone()
		elseif child:IsA("CharacterMesh") then
			table.insert(snapshot.characterMeshes, child:Clone())
		end
	end

	local face = findFaceDecal(character:FindFirstChild("Head"))
	if face then
		snapshot.faceDecal = face:Clone()
	end

	return snapshot
end

local function clearAppearance(character: Model)
	for _, child in character:GetChildren() do
		if child:IsA("Accessory") then
			child.Parent = nil
		end
	end

	for _, child in character:GetChildren() do
		if child:IsA("Shirt") or child:IsA("Pants") or child:IsA("BodyColors") or child:IsA("CharacterMesh") then
			child.Parent = nil
		end
	end

	local head = character:FindFirstChild("Head")
	if head then
		for _, child in head:GetChildren() do
			if child:IsA("Decal") and child.Name == FACE_DECAL_NAME then
				child.Parent = nil
			end
		end
	end
end

local function addAccessoryClone(character: Model, humanoid: Humanoid, accessory: Accessory)
	local newAccessory = accessory:Clone()

	local handle = newAccessory:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		-- Anchored된 Handle은 캐릭터 리그에 정상적으로 웰드되지 않아 허공에 뜨거나 리그가 끊어져 보임.
		(handle :: BasePart).Anchored = false
	end

	newAccessory.Parent = character
	humanoid:AddAccessory(newAccessory)
end

local function applyAppearance(character: Model, humanoid: Humanoid, source: Model | AppearanceSnapshot)
	clearAppearance(character)

	local isSnapshot = typeof(source) == "table"

	if isSnapshot then
		local snapshot = source :: AppearanceSnapshot
		if snapshot.bodyColors then
			snapshot.bodyColors:Clone().Parent = character
		end
		if snapshot.shirt then
			snapshot.shirt:Clone().Parent = character
		end
		if snapshot.pants then
			snapshot.pants:Clone().Parent = character
		end
		for _, mesh in snapshot.characterMeshes do
			mesh:Clone().Parent = character
		end
		if snapshot.faceDecal then
			local head = character:FindFirstChild("Head")
			if head then
				snapshot.faceDecal:Clone().Parent = head
			end
		end
		for _, accessory in snapshot.accessories do
			addAccessoryClone(character, humanoid, accessory)
		end
		return
	end

	local template = source :: Model

	local bodyColors = template:FindFirstChildOfClass("BodyColors")
	if bodyColors then
		bodyColors:Clone().Parent = character
	else
		-- 코스튬 모델에 BodyColors가 없으면 clearAppearance가 지운 자리를 그대로 비워둘 수 없으므로
		-- 로블록스 기본 아바타 배색(Light stone grey/Medium blue/White)으로 채워준다.
		local defaultBodyColors = Instance.new("BodyColors")
		defaultBodyColors.HeadColor = BrickColor.new("Light stone grey")
		defaultBodyColors.LeftArmColor = BrickColor.new("Light stone grey")
		defaultBodyColors.RightArmColor = BrickColor.new("Light stone grey")
		defaultBodyColors.LeftLegColor = BrickColor.new("Medium blue")
		defaultBodyColors.RightLegColor = BrickColor.new("Medium blue")
		defaultBodyColors.TorsoColor = BrickColor.new("White")
		defaultBodyColors.Parent = character
	end

	local shirt = template:FindFirstChildOfClass("Shirt")
	if shirt then
		shirt:Clone().Parent = character
	end

	local pants = template:FindFirstChildOfClass("Pants")
	if pants then
		pants:Clone().Parent = character
	end

	for _, child in template:GetChildren() do
		if child:IsA("CharacterMesh") then
			child:Clone().Parent = character
		end
	end

	local templateFace = findFaceDecal(template:FindFirstChild("Head"))
	if templateFace then
		local head = character:FindFirstChild("Head")
		if head then
			templateFace:Clone().Parent = head
		end
	end

	for _, child in template:GetChildren() do
		if child:IsA("Accessory") then
			addAccessoryClone(character, humanoid, child :: Accessory)
		end
	end
end

--- costumeId로 정의+ReplicatedStorage.Costume 템플릿 Model을 함께 조회. 실패 시 nil 반환(+warn).
local function resolveCostumeTemplate(costumeId: string): (CostumeDefinition?, Model?)
	local def = CostumeHelper.getCostume(costumeId)
	if not def or def.modelName == "" then
		warn("[CostumeHelper] 코스튬 정의/modelName 없음:", costumeId)
		return nil, nil
	end

	local costumeFolder = getCostumeFolder()
	local template = costumeFolder and costumeFolder:FindFirstChild(def.modelName)
	if not template or not template:IsA("Model") then
		warn("[CostumeHelper] Costume 모델 없음:", def.modelName)
		return def, nil
	end

	return def, template :: Model
end

--- 서버 전용: 스폰 시 장착 중인 코스튬을 재적용 (GameManager.onPlayerAdded에서 호출).
--- 코스튬을 실제로 덮어씌우기 전에 이 캐릭터의 "진짜 원래 외형"을 한 번 캡처해둔다 (장착 해제 시 복원용).
function CostumeHelper.applyEquippedCostumeToCharacter(player: Player, character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	if not originalAppearanceByCharacter[character] then
		originalAppearanceByCharacter[character] = snapshotAppearance(character)
	end

	local costumeId = DataManager.getEquippedCostume(player)
	if not costumeId then
		return
	end
	local _, template = resolveCostumeTemplate(costumeId)
	if not template then
		return
	end
	applyAppearance(character, humanoid, template)
end

local function onPreviewRequest(player: Player, costumeId: any)
	if costumeId ~= nil and typeof(costumeId) ~= "string" then
		return
	end

	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	if costumeId == nil then
		local state = previewStateByPlayer[player]
		if state and state.character == character then
			applyAppearance(character, humanoid, state.snapshot)
		end
		previewStateByPlayer[player] = nil
		return
	end

	local _, template = resolveCostumeTemplate(costumeId :: string)
	if not template then
		return
	end

	local state = previewStateByPlayer[player]
	if not state or state.character ~= character then
		state = { character = character, snapshot = snapshotAppearance(character) }
		previewStateByPlayer[player] = state
	end

	applyAppearance(character, humanoid, template)
end

--- 서버 전용: Closet 탭에서 코스튬을 영구 장착(costumeId) 또는 해제(nil). 보유하지 않은 코스튬은 거부.
local function onEquipRequest(player: Player, costumeId: any)
	if costumeId ~= nil and (typeof(costumeId) ~= "string" or costumeId == "") then
		return
	end
	if not DataManager.waitUntilLoaded(player) then
		return
	end

	if costumeId == nil then
		if not DataManager.setEquippedCostume(player, nil) then
			return
		end
		previewStateByPlayer[player] = nil

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if character and humanoid then
			local original = originalAppearanceByCharacter[character]
			if original then
				applyAppearance(character, humanoid, original)
			else
				clearAppearance(character)
			end
		end
		return
	end

	if not DataManager.hasCostume(player, costumeId) then
		warn("[CostumeHelper] 미보유 코스튬 장착 시도:", player.Name, costumeId)
		return
	end

	local _, template = resolveCostumeTemplate(costumeId)
	if not template then
		return
	end
	if not DataManager.setEquippedCostume(player, costumeId) then
		return
	end

	-- 지금 장착한 모습이 새 기준선이 되어야 하므로, 진행 중이던 미리보기 상태는 무효화.
	previewStateByPlayer[player] = nil

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if character and humanoid then
		applyAppearance(character, humanoid, template)
	end
end

--- 서버 전용: 보유 코스튬 목록 + 현재 장착 중인 코스튬 조회.
local function onOwnershipRequest(player: Player): { ownedIds: { string }, equippedId: string? }
	if not DataManager.waitUntilLoaded(player) then
		return { ownedIds = {}, equippedId = nil }
	end
	return {
		ownedIds = DataManager.getOwnedCostumeIds(player),
		equippedId = DataManager.getEquippedCostume(player),
	}
end

--- 서버 전용: Gem/Gold/BattlePassPoint 코스튬 구매. Robux는 MarketplaceService 경로를 따로 씀.
local function onPurchaseRequest(player: Player, costumeId: any): { success: boolean, reason: string? }
	if typeof(costumeId) ~= "string" or costumeId == "" then
		return { success = false, reason = "INVALID_COSTUME" }
	end
	if not DataManager.waitUntilLoaded(player) then
		return { success = false, reason = "NOT_LOADED" }
	end

	local def = CostumeHelper.getCostume(costumeId)
	if not def then
		return { success = false, reason = "INVALID_COSTUME" }
	end
	if def.costType == "Robux" then
		return { success = false, reason = "USE_ROBUX_FLOW" }
	end
	if DataManager.hasCostume(player, costumeId) then
		return { success = false, reason = "ALREADY_OWNED" }
	end

	local currencyType = def.costType :: Types.CurrencyType
	local cost = def.costAmount or 0
	if not DataManager.spendCurrency(player, currencyType, cost) then
		return { success = false, reason = "INSUFFICIENT_FUNDS" }
	end

	if not DataManager.addCostume(player, costumeId) then
		DataManager.addCurrency(player, currencyType, cost)
		return { success = false, reason = "GRANT_FAILED" }
	end

	return { success = true }
end

local purchaseGrantedEvent: RemoteEvent? = nil

--- ShopHelper의 유일한 MarketplaceService.ProcessReceipt에 등록되는 핸들러.
--- productId가 이 코스튬 시스템의 Robux 상품과 일치하면 지급하고 true(처리함) 반환.
local function onRobuxProductGranted(player: Player, productId: number): boolean
	local matchedCostumeId: string? = nil
	for _, id in CostumeHelper.getCostumeIds() do
		local def = CostumeHelper.getCostume(id)
		if def and def.costType == "Robux" and def.productId == productId then
			matchedCostumeId = id
			break
		end
	end
	if not matchedCostumeId then
		return false
	end

	if not DataManager.waitUntilLoaded(player) then
		warn("[CostumeHelper] Robux 코스튬 지급 실패(데이터 미로드):", player.Name, matchedCostumeId)
		return false
	end
	if not DataManager.addCostume(player, matchedCostumeId) then
		warn("[CostumeHelper] Robux 코스튬 지급 실패:", player.Name, matchedCostumeId)
		return false
	end

	if purchaseGrantedEvent then
		purchaseGrantedEvent:FireClient(player, { costumeId = matchedCostumeId })
	end
	return true
end

local function ensureRemote(name: string, className: "RemoteEvent" | "RemoteFunction"): Instance
	local existing = ReplicatedStorage:FindFirstChild(name)
	local remote = if existing and existing:IsA(className) then existing else Instance.new(className)
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

local function bindRemotes()
	local previewRemote = ReplicatedStorage:FindFirstChild(PREVIEW_REMOTE_NAME)
	local remote = if previewRemote and previewRemote:IsA("RemoteEvent") then previewRemote else Instance.new("RemoteEvent")
	remote.Name = PREVIEW_REMOTE_NAME
	remote.Parent = ReplicatedStorage
	remote.OnServerEvent:Connect(onPreviewRequest)

	local function clearState(player: Player)
		previewStateByPlayer[player] = nil
	end

	Players.PlayerRemoving:Connect(clearState)
	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterRemoving:Connect(function(character: Model)
			clearState(player)
			originalAppearanceByCharacter[character] = nil
		end)
	end)

	local equipRemote = ensureRemote(EQUIP_REMOTE_NAME, "RemoteEvent") :: RemoteEvent
	equipRemote.OnServerEvent:Connect(onEquipRequest)

	local ownershipRemote = ensureRemote(OWNERSHIP_REMOTE_NAME, "RemoteFunction") :: RemoteFunction
	ownershipRemote.OnServerInvoke = onOwnershipRequest

	local purchaseRequestRemote = ensureRemote(PURCHASE_REQUEST_REMOTE_NAME, "RemoteFunction") :: RemoteFunction
	purchaseRequestRemote.OnServerInvoke = onPurchaseRequest

	purchaseGrantedEvent = ensureRemote(PURCHASE_GRANTED_EVENT_NAME, "RemoteEvent") :: RemoteEvent

	ShopHelper.registerProductGrantHandler(onRobuxProductGranted)
end

local function getPreviewRemoteOnClient(): RemoteEvent?
	local remote = ReplicatedStorage:FindFirstChild(PREVIEW_REMOTE_NAME)
	if not remote then
		remote = ReplicatedStorage:WaitForChild(PREVIEW_REMOTE_NAME, 10)
	end
	if not (remote and remote:IsA("RemoteEvent")) then
		warn("[CostumeHelper] CostumePreviewRequest RemoteEvent 없음")
		return nil
	end
	return remote :: RemoteEvent
end

--- 클라이언트 전용: 서버에 코스튬 미리보기 적용(costumeId) 또는 해제(nil)를 요청.
function CostumeHelper.requestPreview(costumeId: string?)
	if RunService:IsServer() then
		return
	end
	local remote = getPreviewRemoteOnClient()
	if not remote then
		return
	end
	remote:FireServer(costumeId)
end

local function getClientRemote(name: string, className: "RemoteEvent" | "RemoteFunction"): Instance?
	local remote = ReplicatedStorage:FindFirstChild(name)
	if not remote then
		remote = ReplicatedStorage:WaitForChild(name, 10)
	end
	if not (remote and remote:IsA(className)) then
		warn("[CostumeHelper]", name, className, "없음")
		return nil
	end
	return remote
end

--- 클라이언트 전용: Closet 탭에서 코스튬 영구 장착(costumeId) 또는 장착 해제(nil) 요청.
function CostumeHelper.requestEquip(costumeId: string?)
	if RunService:IsServer() then
		return
	end
	local remote = getClientRemote(EQUIP_REMOTE_NAME, "RemoteEvent") :: RemoteEvent?
	if not remote then
		return
	end
	remote:FireServer(costumeId)
end

--- 클라이언트 전용: 보유 코스튬 목록 + 장착 중인 코스튬 조회.
function CostumeHelper.fetchOwnership(): { ownedIds: { string }, equippedId: string? }?
	if RunService:IsServer() then
		return nil
	end
	local remote = getClientRemote(OWNERSHIP_REMOTE_NAME, "RemoteFunction") :: RemoteFunction?
	if not remote then
		return nil
	end
	local ok, result = pcall(function()
		return remote:InvokeServer()
	end)
	if not ok or typeof(result) ~= "table" then
		warn("[CostumeHelper] GetCostumeOwnership 실패:", result)
		return nil
	end
	return result :: { ownedIds: { string }, equippedId: string? }
end

--- 클라이언트 전용: Gem/Gold/BattlePassPoint 코스튬 구매 요청 (Robux는 MarketplaceService 별도 경로).
function CostumeHelper.requestPurchase(costumeId: string): { success: boolean, reason: string? }
	if RunService:IsServer() then
		return { success = false, reason = "SERVER_CALL" }
	end
	local remote = getClientRemote(PURCHASE_REQUEST_REMOTE_NAME, "RemoteFunction") :: RemoteFunction?
	if not remote then
		return { success = false, reason = "NO_REMOTE" }
	end
	local ok, result = pcall(function()
		return remote:InvokeServer(costumeId)
	end)
	if not ok or typeof(result) ~= "table" then
		warn("[CostumeHelper] CostumePurchaseRequest 실패:", result)
		return { success = false, reason = "INVOKE_FAILED" }
	end
	return result :: { success: boolean, reason: string? }
end

function CostumeHelper.init()
	if initialized then
		return
	end
	initialized = true

	if RunService:IsServer() then
		bindRemotes()
	end
end

CostumeHelper.PURCHASE_GRANTED_EVENT_NAME = PURCHASE_GRANTED_EVENT_NAME

return CostumeHelper
