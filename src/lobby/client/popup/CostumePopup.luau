--[[
	CostumePopup (lobby client)

	GUI 트리: PopupScreenGui.Content.CostumePopup
		Showcase.BtnBuy — 코스튬 미선택 시 Visible=false로 숨김, 선택 시 표시
			Cost.CostIcon / RobuxIcon / CostValue — 선택된 코스튬에 대해 PopupMain.CostumeItem과 동일한 방식으로 세팅
		PopupMain
			Top.CloseButton
			Container.ScrollingContainer.CostumeItem — CostumeData 코스튬 개수만큼 템플릿 복제/캐싱 (최초 1회, LayoutOrder 1부터 증가)
				CostIcon / RobuxIcon — costType == "Robux" 면 RobuxIcon 활성화, 아니면 CostIcon 활성화 + 재화 아이콘(Client.Currency) 세팅
				CostValue — Robux면 GetProductInfoAsync 가격(비동기), 아니면 costAmount
				CostumeName — StringData[costumeId]
				CostumeItem.CostumeIcon — CostumeData[costumeId].iconAssetId
				Btn(ImageButton) — 클릭 시 선택 토글 (같은 코스튬 재클릭 시 선택 해제, 다른 코스튬 클릭 시 전환)
					선택: CostumeItem.UIStroke Color=(255,170,0) Thickness=0.05 / 미선택: Color=(0,0,0) Thickness=0.03

	열기: LobbyScreenGui btnCostume 또는 PopupManager.openPopup(PopupManager.PopupId.Costume)
		카메라를 캐릭터 정면(바라보는 방향)에서 바라보도록 스냅 (CameraZoomModule 거리 재사용) + WalkSpeed 0으로 이동 차단
	닫기: Top.CloseButton — 카메라를 캐릭터 뒤(기본 3인칭)로 다시 스냅 + ScaleModule로 WalkSpeed 복원
	딤 없음 (dim = false)
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)
local StringHelper = require(Shared.Helpers.StringHelper)
local StringBinder = require(Shared.Helpers.StringBinder)
local CostumeHelper = require(Shared.Helpers.CostumeHelper)
local ShopHelper = require(Shared.Helpers.ShopHelper)
local CameraZoomModule = require(Shared.Utils.CameraZoomModule)
local ScaleModule = require(Shared.Utils.ScaleModule)
local CostumeAvatarPreview = require(script.Parent.CostumeAvatarPreview)
local RewardPopup = require(script.Parent.RewardPopup)

local CostumePopup = {}

local POPUP_ROOT_NAME = "CostumePopup"
local LOCALE = "kr"
local CURRENCY_FOLDER_PATH = { "Client", "Currency" }
local CURRENCY_ICON_TYPES = { "Gem", "Gold", "BattlePassPoint" }

local STROKE_COLOR_SELECTED = Color3.fromRGB(255, 170, 0)
local STROKE_THICKNESS_SELECTED = 0.05
local STROKE_COLOR_UNSELECTED = Color3.fromRGB(0, 0, 0)
local STROKE_THICKNESS_UNSELECTED = 0.03

local TAB_COLOR_SELECTED = Color3.fromRGB(251, 155, 27)
local TAB_COLOR_UNSELECTED = Color3.fromRGB(167, 106, 69)
local TAB_MARKETPLACE_NAME = "BtnMarketplace"
local TAB_CLOSET_NAME = "BtnCloset"

local ROBUX_PURCHASE_PROMPT_TIMEOUT_SEC = 120

local initialized = false
local activeSession: { close: () -> () }? = nil
local frontCameraConnection: RBXScriptConnection? = nil
local currentRootGui: GuiObject? = nil

type ActiveTab = "Marketplace" | "Closet"
local activeTab: ActiveTab = "Marketplace"
local ownedCostumeIds: { [string]: boolean } = {}
local equippedCostumeId: string? = nil

local isRobuxPromptOpen = false
local isAwaitingPromptClose = false
local robuxPromptResetToken = 0
local purchaseGrantedConnection: RBXScriptConnection? = nil
local purchaseFinishedConnection: RBXScriptConnection? = nil
local purchaseListenersBound = false

local avatarDragConnections: { RBXScriptConnection } = {}
local avatarDragActive = false
local avatarDragLastX = 0
local avatarDragYaw = 0

local currencyIcons: { [string]: ImageLabel? }? = nil
local itemPoolBuilt = false
local itemPool: { GuiObject } = {}
local itemByCostumeId: { [string]: GuiObject } = {}
local selectedCostumeId: string? = nil

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

local function getCostumePopupRoot(): GuiObject?
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
			warn("[CostumePopup] ReplicatedStorage." .. table.concat(CURRENCY_FOLDER_PATH, ".") .. " 없음")
			return nil
		end
		folder = child
	end

	local icons: { [string]: ImageLabel? } = {}
	for _, currencyType in CURRENCY_ICON_TYPES do
		local iconInst = folder:FindFirstChild(currencyType)
		local icon = if iconInst and iconInst:IsA("ImageLabel") then iconInst :: ImageLabel else nil
		if not icon then
			warn("[CostumePopup] Client.Currency." .. currencyType .. " (ImageLabel) 없음")
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

local function getAvatarLookAtPosition(character: Model): Vector3?
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return nil
	end

	local ok, cf = pcall(function()
		return character:GetBoundingBox()
	end)
	local lookY = if ok and typeof(cf) == "CFrame" then cf.Position.Y else hrp.Position.Y
	return Vector3.new(hrp.Position.X, lookY, hrp.Position.Z)
end

local FRONT_VIEW_SCREEN_X_FRACTION = 0.25 -- 정면 뷰에서 캐릭터가 보일 화면 가로 위치 (0=왼쪽 끝, 0.5=중앙, 1=오른쪽 끝)
local AVATAR_ROTATE_SENSITIVITY = math.rad(0.3) -- 드래그 1픽셀당 아바타 Y축 회전 각도(라디안)

local function getHorizontalFovRad(camera: Camera): number
	local viewportSize = camera.ViewportSize
	local aspect = if viewportSize.Y > 0 then viewportSize.X / viewportSize.Y else 16 / 9
	local verticalFovRad = math.rad(camera.FieldOfView)
	return 2 * math.atan(math.tan(verticalFovRad * 0.5) * aspect)
end

--- camPos에서 lookAt을 바라보되, lookAt이 화면 가로 기준 screenXFraction 위치(0=왼쪽 끝, 0.5=중앙)에 보이도록 살짝 옆을 보는 CFrame.
local function getFramedCameraCFrame(camera: Camera, camPos: Vector3, lookAt: Vector3, screenXFraction: number): CFrame
	local ndcX = 2 * screenXFraction - 1 -- -1(왼쪽 끝) ~ 1(오른쪽 끝), 0=중앙
	if math.abs(ndcX) < 1e-4 then
		return CFrame.lookAt(camPos, lookAt)
	end

	local baseRight = CFrame.lookAt(camPos, lookAt).RightVector
	local distanceToTarget = (lookAt - camPos).Magnitude
	local halfHorizontalFov = getHorizontalFovRad(camera) * 0.5
	local lateralShift = -ndcX * distanceToTarget * math.tan(halfHorizontalFov)
	local aimPoint = lookAt + baseRight * lateralShift
	return CFrame.lookAt(camPos, aimPoint)
end

--- viewFromFront=true면 캐릭터가 바라보는 방향(정면)에서, false면 뒤(기본 3인칭)에서 캐릭터를 바라보는 CFrame.
local function getAvatarSnapCameraCFrame(camera: Camera, character: Model, viewFromFront: boolean): CFrame?
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return nil
	end
	local lookAt = getAvatarLookAtPosition(character)
	if not lookAt then
		return nil
	end

	local scale = CameraZoomModule.getCharacterScale(character)
	local distance = CameraZoomModule.getFixedDistance(scale)

	local direction = if viewFromFront then hrp.CFrame.LookVector else -hrp.CFrame.LookVector
	if direction.Magnitude < 0.01 then
		direction = Vector3.new(0, 0, if viewFromFront then -1 else 1)
	else
		direction = direction.Unit
	end

	if viewFromFront and avatarDragYaw ~= 0 then
		direction = CFrame.fromAxisAngle(Vector3.yAxis, avatarDragYaw) * direction
	end

	local camPos = lookAt + direction * distance
	local screenXFraction = if viewFromFront then FRONT_VIEW_SCREEN_X_FRACTION else 0.5
	return getFramedCameraCFrame(camera, camPos, lookAt, screenXFraction)
end

local function lockPlayerMovement()
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
	end
end

local function unlockPlayerMovement()
	local character = Players.LocalPlayer.Character
	if character then
		ScaleModule.applyWalkSpeedForCharacter(character)
	end
end

--- Scriptable로 CFrame을 강제한 뒤 즉시 Custom으로 돌려 플레이어가 이어서 카메라를 조작할 수 있게 함.
local function snapAvatarCamera(viewFromFront: boolean)
	local character = Players.LocalPlayer.Character
	if not character then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local targetCf = getAvatarSnapCameraCFrame(camera, character, viewFromFront)
	if not targetCf then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = targetCf
	camera.CameraType = Enum.CameraType.Custom
	if humanoid and humanoid.Parent then
		camera.CameraSubject = humanoid
	end
end

--- Custom 카메라는 매 프레임 CameraSubject를 향해 재중앙 정렬하므로,
--- 화면 25% 위치로 튼 앵글은 Scriptable을 유지한 채 매 프레임 다시 세팅해야 유지됨.
local function updateFrontCameraFrame()
	local character = Players.LocalPlayer.Character
	local camera = Workspace.CurrentCamera
	if not character or not camera then
		return
	end
	local targetCf = getAvatarSnapCameraCFrame(camera, character, true)
	if targetCf then
		camera.CFrame = targetCf
	end
end

--- PC 마우스 좌클릭 드래그 / 모바일 터치 드래그의 좌우 이동량만큼 avatarDragYaw를 누적.
--- 실제 캐릭터를 회전시키지 않고 카메라가 캐릭터 주위를 도는 방식이라 다른 클라이언트 시야나 물리에는 영향 없음.
local function isAvatarRotateInputType(inputType: Enum.UserInputType): boolean
	return inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch
end

local function onAvatarDragInputBegan(input: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent or not isAvatarRotateInputType(input.UserInputType) then
		return
	end
	avatarDragActive = true
	avatarDragLastX = input.Position.X
end

local function onAvatarDragInputChanged(input: InputObject)
	if not avatarDragActive then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local deltaX = input.Position.X - avatarDragLastX
	avatarDragLastX = input.Position.X
	avatarDragYaw -= deltaX * AVATAR_ROTATE_SENSITIVITY
end

local function onAvatarDragInputEnded(input: InputObject)
	if isAvatarRotateInputType(input.UserInputType) then
		avatarDragActive = false
	end
end

local function beginAvatarDrag()
	avatarDragYaw = 0
	avatarDragActive = false
	table.insert(avatarDragConnections, UserInputService.InputBegan:Connect(onAvatarDragInputBegan))
	table.insert(avatarDragConnections, UserInputService.InputChanged:Connect(onAvatarDragInputChanged))
	table.insert(avatarDragConnections, UserInputService.InputEnded:Connect(onAvatarDragInputEnded))
end

local function endAvatarDrag()
	for _, c in avatarDragConnections do
		c:Disconnect()
	end
	table.clear(avatarDragConnections)
	avatarDragActive = false
end

local function beginFrontCamera()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if frontCameraConnection then
		frontCameraConnection:Disconnect()
		frontCameraConnection = nil
	end
	camera.CameraType = Enum.CameraType.Scriptable
	updateFrontCameraFrame()
	frontCameraConnection = RunService.RenderStepped:Connect(updateFrontCameraFrame)
	beginAvatarDrag()
end

local function endFrontCamera()
	if frontCameraConnection then
		frontCameraConnection:Disconnect()
		frontCameraConnection = nil
	end
	endAvatarDrag()
	snapAvatarCamera(false)
end

local function findPopupMain(rootGui: GuiObject): GuiObject?
	local popupMain = rootGui:FindFirstChild("PopupMain")
	if popupMain and popupMain:IsA("GuiObject") then
		return popupMain :: GuiObject
	end
	return nil
end

local function findScrollingContainer(popupMain: GuiObject): GuiObject?
	local container = popupMain:FindFirstChild("Container")
	local scrollingContainer = container and container:FindFirstChild("ScrollingContainer")
	if scrollingContainer and scrollingContainer:IsA("GuiObject") then
		return scrollingContainer :: GuiObject
	end
	return nil
end

local function findCostumeItemTemplate(scrollingContainer: GuiObject): GuiObject?
	local templateInst = scrollingContainer:FindFirstChild("CostumeItem")
	if templateInst and templateInst:IsA("GuiObject") then
		return templateInst :: GuiObject
	end
	return nil
end

local function findTabButton(rootGui: GuiObject, name: string): GuiButton?
	local popupMain = findPopupMain(rootGui)
	local tabs = popupMain and popupMain:FindFirstChild("Tabs")
	local btnInst = tabs and tabs:FindFirstChild(name)
	if btnInst and btnInst:IsA("GuiButton") then
		return btnInst :: GuiButton
	end
	return nil
end

local function applyTabVisual(tabBtn: GuiButton, selected: boolean)
	local imgTabInst = tabBtn:FindFirstChild("ImgTab")
	if not (imgTabInst and imgTabInst:IsA("ImageLabel")) then
		warn("[CostumePopup]", tabBtn.Name, "ImgTab (ImageLabel) 없음")
		return
	end
	(imgTabInst :: ImageLabel).ImageColor3 = if selected then TAB_COLOR_SELECTED else TAB_COLOR_UNSELECTED
end

local function findShowcaseClosetButton(rootGui: GuiObject): GuiButton?
	local showcase = rootGui:FindFirstChild("Showcase")
	local btnCloset = showcase and showcase:FindFirstChild("BtnCloset")
	if btnCloset and btnCloset:IsA("GuiButton") then
		return btnCloset :: GuiButton
	end
	return nil
end

local function applyCostToggle(item: GuiObject, def: CostumeHelper.CostumeDefinition)
	local isRobux = def.costType == "Robux"

	local costIconInst = item:FindFirstChild("CostIcon")
	if costIconInst and costIconInst:IsA("GuiObject") then
		(costIconInst :: GuiObject).Visible = not isRobux
	end

	local robuxIconInst = item:FindFirstChild("RobuxIcon")
	if robuxIconInst and robuxIconInst:IsA("GuiObject") then
		(robuxIconInst :: GuiObject).Visible = isRobux
	end

	if not isRobux and costIconInst and costIconInst:IsA("ImageLabel") then
		local icons = resolveCurrencyIcons()
		local sourceIcon = icons and icons[def.costType]
		if sourceIcon then
			applyImageLabelImageProperties(sourceIcon, costIconInst :: ImageLabel)
		end
	end
end

local function applyCostValue(item: GuiObject, def: CostumeHelper.CostumeDefinition)
	local costValueInst = item:FindFirstChild("CostValue")
	if not (costValueInst and costValueInst:IsA("TextLabel")) then
		warn("[CostumePopup]", item.Name, "CostValue (TextLabel) 없음")
		return
	end
	local costValue = costValueInst :: TextLabel

	if def.costType ~= "Robux" then
		costValue.Text = tostring(def.costAmount or 0)
		return
	end

	local productId = def.productId
	if not productId then
		return
	end
	task.spawn(function()
		local price = CostumeHelper.fetchRobuxPrice(productId)
		if price then
			costValue.Text = tostring(price)
		end
	end)
end

local function applyCostumeName(item: GuiObject, costumeId: string)
	local costumeNameInst = item:FindFirstChild("CostumeName")
	if costumeNameInst and costumeNameInst:IsA("TextLabel") then
		(costumeNameInst :: TextLabel).Text = StringHelper.get(costumeId, LOCALE)
	else
		warn("[CostumePopup]", item.Name, "CostumeName (TextLabel) 없음")
	end
end

local function findInnerCostumeFrame(item: GuiObject): GuiObject?
	local innerFrame = item:FindFirstChild("CostumeItem")
	if innerFrame and innerFrame:IsA("GuiObject") then
		return innerFrame :: GuiObject
	end
	return nil
end

local function applyCostumeIcon(item: GuiObject, def: CostumeHelper.CostumeDefinition)
	local innerFrame = findInnerCostumeFrame(item)
	local costumeIconInst = innerFrame and innerFrame:FindFirstChild("CostumeIcon")
	if costumeIconInst and costumeIconInst:IsA("ImageLabel") then
		(costumeIconInst :: ImageLabel).Image = def.iconAssetId
	else
		warn("[CostumePopup]", item.Name, "CostumeItem.CostumeIcon (ImageLabel) 없음")
	end
end

local function applyCostumeItemStroke(item: GuiObject, isSelected: boolean)
	local innerFrame = findInnerCostumeFrame(item)
	local strokeInst = innerFrame and innerFrame:FindFirstChild("UIStroke")
	if not (strokeInst and strokeInst:IsA("UIStroke")) then
		warn("[CostumePopup]", item.Name, "CostumeItem.UIStroke 없음")
		return
	end

	local stroke = strokeInst :: UIStroke
	if isSelected then
		stroke.Color = STROKE_COLOR_SELECTED
		stroke.Thickness = STROKE_THICKNESS_SELECTED
	else
		stroke.Color = STROKE_COLOR_UNSELECTED
		stroke.Thickness = STROKE_THICKNESS_UNSELECTED
	end
end

local function bindCostumeItem(item: GuiObject, costumeId: string)
	local def = CostumeHelper.getCostume(costumeId)
	if not def then
		warn("[CostumePopup] CostumeData에 없는 코스튬:", costumeId)
		return
	end

	applyCostToggle(item, def)
	applyCostValue(item, def)
	applyCostumeName(item, costumeId)
	applyCostumeIcon(item, def)
end

--- Closet 탭 진입 시 CostIcon/CostValue/RobuxIcon을 전부 숨김 (이미 보유한 코스튬이라 가격 표시 불필요).
local function hideCostumeItemCostUI(item: GuiObject)
	for _, childName in { "CostIcon", "CostValue", "RobuxIcon" } do
		local childInst = item:FindFirstChild(childName)
		if childInst and childInst:IsA("GuiObject") then
			(childInst :: GuiObject).Visible = false
		end
	end
end

--- Marketplace 탭 복귀 시 코스튬별 costType에 맞춰 CostIcon/CostValue/RobuxIcon 표시를 되살림.
local function restoreCostumeItemCostUI(item: GuiObject, costumeId: string)
	local def = CostumeHelper.getCostume(costumeId)
	if not def then
		return
	end
	local costValueInst = item:FindFirstChild("CostValue")
	if costValueInst and costValueInst:IsA("GuiObject") then
		(costValueInst :: GuiObject).Visible = true
	end
	applyCostToggle(item, def)
end

local function findShowcaseBuyButton(rootGui: GuiObject): GuiButton?
	local showcase = rootGui:FindFirstChild("Showcase")
	local btnBuy = showcase and showcase:FindFirstChild("BtnBuy")
	if btnBuy and btnBuy:IsA("GuiButton") then
		return btnBuy :: GuiButton
	end
	return nil
end

local function setBuyButtonEnabled(btnBuy: GuiButton, enabled: boolean)
	btnBuy.Visible = enabled
end

--- costumeId가 nil이면 미선택 상태로 BtnBuy/BtnCloset 모두 비활성화(Visible=false).
--- costumeId가 있으면 보유 여부에 따라 BtnBuy(미보유, Cost 세팅)와 BtnCloset(보유) 중 하나만 노출.
local function applyShowcaseSelection(rootGui: GuiObject, costumeId: string?)
	local btnBuy = findShowcaseBuyButton(rootGui)
	if not btnBuy then
		warn("[CostumePopup] Showcase.BtnBuy (GuiButton) 없음")
		return
	end
	local btnCloset = findShowcaseClosetButton(rootGui)

	local def = if costumeId then CostumeHelper.getCostume(costumeId) else nil
	if not def then
		setBuyButtonEnabled(btnBuy, false)
		if btnCloset then
			btnCloset.Visible = false
		end
		return
	end

	local owned = ownedCostumeIds[costumeId :: string] == true
	setBuyButtonEnabled(btnBuy, not owned)
	if btnCloset then
		btnCloset.Visible = owned
	end

	if owned then
		return
	end

	local costFrame = btnBuy:FindFirstChild("Cost")
	if not costFrame or not costFrame:IsA("GuiObject") then
		warn("[CostumePopup] Showcase.BtnBuy.Cost 없음")
		return
	end

	applyCostToggle(costFrame :: GuiObject, def)
	applyCostValue(costFrame :: GuiObject, def)
end

--- 같은 코스튬을 다시 클릭하면 선택 해제, 다른 코스튬을 클릭하면 그 코스튬으로 선택 전환.
local function setCostumeSelected(rootGui: GuiObject, costumeId: string?)
	if selectedCostumeId then
		local prevItem = itemByCostumeId[selectedCostumeId]
		if prevItem then
			applyCostumeItemStroke(prevItem, false)
		end
	end

	selectedCostumeId = costumeId

	if selectedCostumeId then
		local newItem = itemByCostumeId[selectedCostumeId]
		if newItem then
			applyCostumeItemStroke(newItem, true)
		end
		CostumeAvatarPreview.apply(selectedCostumeId)
	else
		CostumeAvatarPreview.clear()
	end

	applyShowcaseSelection(rootGui, selectedCostumeId)
end

--- Closet 탭 전용: 보유 코스튬 클릭 시 그 코스튬으로 영구 장착. 이미 장착 중인 코스튬을 다시 클릭하면 장착 해제
--- (GUI 선택 상태도 함께 해제).
local function onClosetItemClicked(costumeId: string)
	if not ownedCostumeIds[costumeId] then
		return
	end

	if selectedCostumeId then
		local prevItem = itemByCostumeId[selectedCostumeId]
		if prevItem then
			applyCostumeItemStroke(prevItem, false)
		end
	end

	if equippedCostumeId == costumeId then
		selectedCostumeId = nil
		equippedCostumeId = nil
		CostumeHelper.requestEquip(nil)
		return
	end

	selectedCostumeId = costumeId
	equippedCostumeId = costumeId

	local newItem = itemByCostumeId[costumeId]
	if newItem then
		applyCostumeItemStroke(newItem, true)
	end

	CostumeHelper.requestEquip(costumeId)
end

local function onCostumeItemClicked(rootGui: GuiObject, costumeId: string)
	if activeTab == "Closet" then
		onClosetItemClicked(costumeId)
		return
	end

	if selectedCostumeId == costumeId then
		setCostumeSelected(rootGui, nil)
	else
		setCostumeSelected(rootGui, costumeId)
	end
end

--- 탭 전환: Marketplace(전체 목록, 미리보기) ↔ Closet(보유만, 장착 중인 것 선택 표시, Showcase 숨김).
local function setActiveTab(rootGui: GuiObject, tab: ActiveTab)
	activeTab = tab

	local marketplaceBtn = findTabButton(rootGui, TAB_MARKETPLACE_NAME)
	if marketplaceBtn then
		applyTabVisual(marketplaceBtn, tab == "Marketplace")
	end
	local closetTabBtn = findTabButton(rootGui, TAB_CLOSET_NAME)
	if closetTabBtn then
		applyTabVisual(closetTabBtn, tab == "Closet")
	end

	if tab == "Closet" then
		if selectedCostumeId then
			CostumeAvatarPreview.clear()
		end

		for id, item in itemByCostumeId do
			item.Visible = ownedCostumeIds[id] == true
			applyCostumeItemStroke(item, id == equippedCostumeId)
			hideCostumeItemCostUI(item)
		end
		selectedCostumeId = equippedCostumeId

		local btnBuy = findShowcaseBuyButton(rootGui)
		if btnBuy then
			btnBuy.Visible = false
		end
		local btnCloset = findShowcaseClosetButton(rootGui)
		if btnCloset then
			btnCloset.Visible = false
		end
	else
		for id, item in itemByCostumeId do
			item.Visible = true
			restoreCostumeItemCostUI(item, id)
		end
		if selectedCostumeId then
			local prevItem = itemByCostumeId[selectedCostumeId]
			if prevItem then
				applyCostumeItemStroke(prevItem, false)
			end
		end
		selectedCostumeId = nil
		applyShowcaseSelection(rootGui, nil)
	end
end

--- 구매 완료 처리 공통: 보유 목록 갱신 + (선택 중이면) Showcase 갱신 + 코스튬 아이콘으로 RewardPopup 표시.
local function onCostumePurchased(costumeId: string)
	ownedCostumeIds[costumeId] = true

	if currentRootGui and selectedCostumeId == costumeId then
		applyShowcaseSelection(currentRootGui, costumeId)
	end
	if currentRootGui and activeTab == "Closet" then
		local item = itemByCostumeId[costumeId]
		if item then
			item.Visible = true
		end
	end

	local def = CostumeHelper.getCostume(costumeId)
	if def then
		task.defer(function()
			RewardPopup.open(RewardPopup.TitleType.Purchase, { customImage = def.iconAssetId, amount = 1 })
		end)
	end
end

local pendingGrantedCostumeId: string? = nil

local function clearRobuxPromptState()
	isRobuxPromptOpen = false
	isAwaitingPromptClose = false
end

local function tryShowPendingRobuxReward()
	if not pendingGrantedCostumeId or isAwaitingPromptClose then
		return
	end
	local costumeId = pendingGrantedCostumeId
	pendingGrantedCostumeId = nil
	onCostumePurchased(costumeId)
end

local function scheduleRobuxPromptReset(token: number)
	task.delay(ROBUX_PURCHASE_PROMPT_TIMEOUT_SEC, function()
		if robuxPromptResetToken ~= token then
			return
		end
		clearRobuxPromptState()
		tryShowPendingRobuxReward()
	end)
end

local function onRobuxPurchaseGranted(payload: any)
	if typeof(payload) ~= "table" or typeof(payload.costumeId) ~= "string" then
		warn("[CostumePopup] CostumePurchaseGranted payload 형식 오류:", payload)
		return
	end
	pendingGrantedCostumeId = payload.costumeId
	tryShowPendingRobuxReward()
end

local function promptRobuxPurchase(productId: number)
	if isRobuxPromptOpen then
		return
	end
	isRobuxPromptOpen = true
	isAwaitingPromptClose = true
	robuxPromptResetToken += 1
	local token = robuxPromptResetToken
	scheduleRobuxPromptReset(token)

	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(Players.LocalPlayer, productId)
	end)
	if not ok then
		warn("[CostumePopup] PromptProductPurchase 실패 productId=", productId, err)
		clearRobuxPromptState()
	end
end

--- 클라이언트 세션 동안 한 번만 연결 (ShopPopup의 동일 패턴 참고: 서버 지급 이벤트 + 네이티브 구매창 종료 이벤트
--- 둘 다 도착해야 보상을 표시).
local function bindCostumePurchaseListeners()
	if purchaseListenersBound then
		return
	end
	purchaseListenersBound = true

	local eventInst = ReplicatedStorage:WaitForChild(CostumeHelper.PURCHASE_GRANTED_EVENT_NAME, 10)
	if not (eventInst and eventInst:IsA("RemoteEvent")) then
		warn("[CostumePopup]", CostumeHelper.PURCHASE_GRANTED_EVENT_NAME, "RemoteEvent 없음")
		return
	end

	purchaseGrantedConnection = (eventInst :: RemoteEvent).OnClientEvent:Connect(onRobuxPurchaseGranted)
	purchaseFinishedConnection = MarketplaceService.PromptProductPurchaseFinished:Connect(
		function(userId: number, _productId: number, wasPurchased: boolean)
			if userId ~= Players.LocalPlayer.UserId then
				return
			end
			isAwaitingPromptClose = false
			clearRobuxPromptState()
			if not wasPurchased then
				pendingGrantedCostumeId = nil
				return
			end
			tryShowPendingRobuxReward()
		end
	)
end

local GEM_TOP_UP_PRODUCT_INDEX = 1

--- Gem 부족으로 코스튬 구매가 실패했을 때, ShopData products[1](Gem 충전 상품)의 로벅스 구매창을 띄운다.
--- 실제 Gem 지급/보상 표시는 ShopPopup.init()에서 이미 전역으로 연결된 구매 리스너가 처리한다.
local function promptGemTopUp()
	local product = ShopHelper.getProduct(GEM_TOP_UP_PRODUCT_INDEX)
	if not product then
		warn("[CostumePopup] ShopData products[" .. GEM_TOP_UP_PRODUCT_INDEX .. "] 없음 (Gem 충전용)")
		return
	end
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(Players.LocalPlayer, product.productId)
	end)
	if not ok then
		warn("[CostumePopup] Gem 충전 PromptProductPurchase 실패:", err)
	end
end

--- Robux는 MarketplaceService 프롬프트로, 그 외(Gem/Gold/BattlePassPoint)는 서버에 즉시 요청.
--- Gem 상품이 잔액 부족으로 실패하면 Gem 충전 구매창을 띄운다.
local function purchaseCostume(costumeId: string)
	local def = CostumeHelper.getCostume(costumeId)
	if not def then
		return
	end

	if def.costType == "Robux" then
		if not def.productId then
			warn("[CostumePopup] Robux 코스튬 productId 없음:", costumeId)
			return
		end
		promptRobuxPurchase(def.productId)
		return
	end

	local result = CostumeHelper.requestPurchase(costumeId)
	if result.success then
		onCostumePurchased(costumeId)
		return
	end

	if result.reason == "INSUFFICIENT_FUNDS" and def.costType == "Gem" then
		promptGemTopUp()
		return
	end

	warn("[CostumePopup] 코스튬 구매 실패:", costumeId, result.reason)
end

local function ensureItemPool(rootGui: GuiObject): boolean
	if itemPoolBuilt then
		return #itemPool > 0
	end

	local popupMain = findPopupMain(rootGui)
	if not popupMain then
		warn("[CostumePopup] PopupMain 없음")
		return false
	end

	local scrollingContainer = findScrollingContainer(popupMain)
	if not scrollingContainer then
		warn("[CostumePopup] PopupMain.Container.ScrollingContainer 없음")
		return false
	end

	local template = findCostumeItemTemplate(scrollingContainer)
	if not template then
		warn("[CostumePopup] Container.ScrollingContainer.CostumeItem 없음")
		return false
	end

	template.Visible = false
	itemPool = {}

	local layoutOrder = 0
	for _, costumeId in CostumeHelper.getCostumeIds() do
		layoutOrder += 1
		local cloneInst = template:Clone()
		cloneInst.Name = "CostumeItem_" .. costumeId
		cloneInst.Visible = true
		cloneInst.LayoutOrder = layoutOrder
		cloneInst.Parent = scrollingContainer
		table.insert(itemPool, cloneInst)
		itemByCostumeId[costumeId] = cloneInst
		bindCostumeItem(cloneInst, costumeId)
		applyCostumeItemStroke(cloneInst, false)

		local btnInst = cloneInst:FindFirstChild("Btn")
		if btnInst and btnInst:IsA("GuiButton") then
			local btn = btnInst :: GuiButton
			prepareClickableButton(btn)
			btn.Activated:Connect(function()
				onCostumeItemClicked(rootGui, costumeId)
			end)
		else
			warn("[CostumePopup]", cloneInst.Name, "Btn (ImageButton) 없음")
		end
	end

	itemPoolBuilt = true
	return #itemPool > 0
end

function CostumePopup.open(skipEntranceAnimation: boolean?)
	if activeSession then
		return
	end

	local rootGui = getCostumePopupRoot()
	if not rootGui then
		warn("[CostumePopup] Content.CostumePopup 없음")
		return
	end
	StringBinder.applySubtreeOnce(rootGui)
	ensureItemPool(rootGui)
	currentRootGui = rootGui

	local ownership = CostumeHelper.fetchOwnership()
	ownedCostumeIds = {}
	if ownership then
		for _, id in ownership.ownedIds do
			ownedCostumeIds[id] = true
		end
		equippedCostumeId = ownership.equippedId
	else
		equippedCostumeId = nil
	end

	-- 매번 Marketplace 탭 + 미선택 상태로 새로 시작 (이전 세션의 미리보기 선택은 유지하지 않음).
	-- selectedCostumeId를 미리 nil로 지우면 setActiveTab이 이전 선택 아이템의 UIStroke를
	-- 해제하지 못하므로, 기존 값을 그대로 둔 채 setActiveTab이 스스로 정리하게 한다.
	setActiveTab(rootGui, "Marketplace")

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[CostumePopup] Content 없음")
		return
	end

	local popupMain = findPopupMain(rootGui)
	local top = popupMain and popupMain:FindFirstChild("Top")
	local closeInst = top and top:FindFirstChild("CloseButton")
	if not (closeInst and closeInst:IsA("GuiButton")) then
		warn("[CostumePopup] PopupMain.Top.CloseButton 없음")
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
		endFrontCamera()
		unlockPlayerMovement()
		CostumeAvatarPreview.clear()
		currentRootGui = nil
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
		currentRootGui = nil
		return
	end
	rootGui.Visible = true
	if pushOptions.playEntranceAnimation then
		PopupManager.playBounceEntrance(rootGui)
	end

	prepareClickableButton(closeBtn)
	table.insert(connections, closeBtn.Activated:Connect(close))

	local btnBuy = findShowcaseBuyButton(rootGui)
	if btnBuy then
		prepareClickableButton(btnBuy)
		table.insert(connections, btnBuy.Activated:Connect(function()
			if selectedCostumeId then
				purchaseCostume(selectedCostumeId)
			end
		end))
	else
		warn("[CostumePopup] Showcase.BtnBuy (GuiButton) 없음")
	end

	local btnCloset = findShowcaseClosetButton(rootGui)
	if btnCloset then
		prepareClickableButton(btnCloset)
		table.insert(connections, btnCloset.Activated:Connect(function()
			setActiveTab(rootGui, "Closet")
		end))
	else
		warn("[CostumePopup] Showcase.BtnCloset (GuiButton) 없음")
	end

	local marketplaceTabBtn = findTabButton(rootGui, TAB_MARKETPLACE_NAME)
	if marketplaceTabBtn then
		prepareClickableButton(marketplaceTabBtn)
		table.insert(connections, marketplaceTabBtn.Activated:Connect(function()
			setActiveTab(rootGui, "Marketplace")
		end))
	else
		warn("[CostumePopup] Tabs.BtnMarketplace (GuiButton) 없음")
	end

	local closetTabBtn = findTabButton(rootGui, TAB_CLOSET_NAME)
	if closetTabBtn then
		prepareClickableButton(closetTabBtn)
		table.insert(connections, closetTabBtn.Activated:Connect(function()
			setActiveTab(rootGui, "Closet")
		end))
	else
		warn("[CostumePopup] Tabs.BtnCloset (GuiButton) 없음")
	end

	beginFrontCamera()
	lockPlayerMovement()

	activeSession = { close = close }
end

function CostumePopup.close()
	if activeSession then
		activeSession.close()
	end
end

function CostumePopup.init()
	if initialized then
		return
	end
	initialized = true
	bindCostumePurchaseListeners()
	print("[CostumePopup] 초기화 완료")
end

return CostumePopup
