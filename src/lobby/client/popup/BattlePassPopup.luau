--[[
	BattlePassPopup (lobby client)

	열기: LobbyScreenGui.LeftButtons.btnBattlePass
	닫기: Top.CloseButton
	딤 없음 (dim = false)

	Container.TxtRemainTime — 시즌 종료(seasonEndTime)까지 남은 시간
	Container.PassInfo.Gauge — TxtPassLevel, XPBar.Fill, XPBar.TxtProgress
	Container.CanvasGroup.ScrollingFrame.BattlePassItem — 레벨별 보상 트랙 템플릿 (복제 캐싱)

	프리미엄 패스 구매:
		서버 UserOwnsGamePassAsync → OwnsPremiumBattlePass Attribute
		Container.LeftPanel.BtnBuy → PromptGamePassPurchase
		구매창 닫힐 때 서버 재확인 → BtnBuy 숨김

	RewardIcon: ReplicatedStorage.Client.{Currency.{Gem,Gold,BattlePassPoint} | Relic | Costume | Item.{ItemData.icon}} 의 이미지 속성만 복사.

	FreeReward/PremiumReward BtnReward 클릭 시 보상이 Item이고 아직 수령 완료 상태가 아니면(claimable/locked)
	실제 수령 대신 ItemInfoPopup을 띄움. BattlePassPopup을 닫으면 열려 있는 ItemInfoPopup도 함께 닫힘.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local BattlePassHelper = require(Shared.Helpers.BattlePassHelper)
local ShopHelper = require(Shared.Helpers.ShopHelper)
local StringHelper = require(Shared.Helpers.StringHelper)
local StringBinder = require(Shared.Helpers.StringBinder)
local RelicHelper = require(Shared.Helpers.RelicHelper)
local InventoryHelper = require(Shared.Helpers.InventoryHelper)
local PopupManager = require(Shared.Managers.PopupManager)
local BattlePassClient = require(script.Parent.Parent.BattlePassClient)
local RewardPopup = require(script.Parent.RewardPopup)
local ItemInfoPopup = require(script.Parent.ItemInfoPopup)

local BattlePassPopup = {}

type BattlePassSnapshot = BattlePassHelper.BattlePassSnapshot
type BattlePassRewardTrack = BattlePassHelper.BattlePassRewardTrack
type Reward = Types.Reward
type RewardPopupEntry = RewardPopup.RewardEntry

local POPUP_ROOT_NAME = "BattlePassPopup"
local LOCALE = "kr"
local REMAIN_TIME_UPDATE_INTERVAL = 0.1
local CURRENCY_FOLDER_PATH = { "Client", "Currency" }
local COSTUME_DATA_MODULE_NAME = "CostumeData"

local initialized = false
local activeSession: { close: () -> () }? = nil
local isPurchasePromptOpen = false
local purchaseFinishedConnection: RBXScriptConnection? = nil
local ownsPassAttributeConnection: RBXScriptConnection? = nil
local isJumpLevelPromptOpen = false
local jumpLevelPurchaseGrantedConnection: RBXScriptConnection? = nil
local jumpLevelPromptFinishedConnection: RBXScriptConnection? = nil

local cachedPassPrice: number? = nil
local cachedOwnsPass: boolean? = nil
local currencyIcons: { [string]: ImageLabel? }? = nil
local costumeIconAssetIdById: { [string]: string }? = nil
local itemPoolBuilt = false
local itemPool: { GuiObject } = {}
local isClaiming = false
local rewardButtonsBound = false

local function resolveCurrencyIcons(): { [string]: ImageLabel? }?
	if currencyIcons then
		return currencyIcons
	end

	local folder: Instance = ReplicatedStorage
	for _, name in CURRENCY_FOLDER_PATH do
		local child = folder:FindFirstChild(name)
		if not child then
			warn("[BattlePassPopup] ReplicatedStorage." .. table.concat(CURRENCY_FOLDER_PATH, ".") .. " 없음")
			return nil
		end
		folder = child
	end

	local icons: { [string]: ImageLabel? } = {}
	for _, currencyType in { "Gem", "Gold", "BattlePassPoint" } do
		local iconInst = folder:FindFirstChild(currencyType)
		local icon = if iconInst and iconInst:IsA("ImageLabel") then iconInst :: ImageLabel else nil
		if not icon then
			warn("[BattlePassPopup] Client.Currency." .. currencyType .. " (ImageLabel) 없음")
		end
		icons[currencyType] = icon
	end

	currencyIcons = icons
	return currencyIcons
end

local function resolveCostumeIconAssetIdById(): { [string]: string }
	if costumeIconAssetIdById then
		return costumeIconAssetIdById
	end

	local map: { [string]: string } = {}
	local dataTableFolder = ReplicatedStorage:FindFirstChild("DataTable")
	local costumeModule = dataTableFolder and dataTableFolder:FindFirstChild(COSTUME_DATA_MODULE_NAME)
	if costumeModule and costumeModule:IsA("ModuleScript") then
		local ok, result = pcall(function()
			return require(costumeModule :: ModuleScript)
		end)
		if ok and typeof(result) == "table" and typeof(result.costumes) == "table" then
			for costumeId, row in result.costumes do
				if typeof(costumeId) == "string" and typeof(row) == "table" and typeof(row.iconAssetId) == "string" then
					map[costumeId] = row.iconAssetId
				end
			end
		else
			warn("[BattlePassPopup] CostumeData 로드 실패:", result)
		end
	end

	costumeIconAssetIdById = map
	return map
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

local function formatRewardCountText(reward: Reward): string
	if reward.rewardType == "Currency" or reward.rewardType == "Item" then
		return tostring(math.floor(reward.amount))
	end
	return "1"
end

local function applyRewardIcon(rewardIcon: ImageLabel, reward: Reward, icons: { [string]: ImageLabel? })
	if reward.rewardType == "Currency" then
		local sourceIcon = icons[reward.currencyType]
		if sourceIcon then
			applyImageLabelImageProperties(sourceIcon, rewardIcon)
		end
		return
	end

	local clientFolder = ReplicatedStorage:FindFirstChild("Client")
	if not clientFolder then
		return
	end

	local iconName: string? = nil
	local categoryFolderName: string? = nil
	if reward.rewardType == "Relic" then
		categoryFolderName = "Relic"
		local def = RelicHelper.getRelic(reward.id)
		iconName = if def and def.icon ~= "" then def.icon else nil
	elseif reward.rewardType == "Costume" then
		categoryFolderName = "Costume"
		iconName = reward.id
	elseif reward.rewardType == "Item" then
		categoryFolderName = "Item"
		iconName = InventoryHelper.getItemIconName(reward.itemType)
	end

	if not categoryFolderName or not iconName then
		return
	end

	local categoryFolder = clientFolder:FindFirstChild(categoryFolderName)
	local iconInst = categoryFolder and categoryFolder:FindFirstChild(iconName)
	if iconInst and iconInst:IsA("ImageLabel") then
		applyImageLabelImageProperties(iconInst :: ImageLabel, rewardIcon)
	end
end

local function findScrollingFrame(rootGui: GuiObject): ScrollingFrame?
	local container = rootGui:FindFirstChild("Container")
	local canvasGroup = container and container:FindFirstChild("CanvasGroup")
	local scrollingInst = canvasGroup and canvasGroup:FindFirstChild("ScrollingFrame")
	if scrollingInst and scrollingInst:IsA("ScrollingFrame") then
		return scrollingInst :: ScrollingFrame
	end
	return nil
end

local function findBattlePassItemTemplate(scrollingFrame: ScrollingFrame): GuiObject?
	local templateInst = scrollingFrame:FindFirstChild("BattlePassItem")
	if templateInst and templateInst:IsA("GuiObject") then
		return templateInst :: GuiObject
	end
	return nil
end

local function ensureItemPool(rootGui: GuiObject): boolean
	if itemPoolBuilt then
		return #itemPool > 0
	end

	local scrollingFrame = findScrollingFrame(rootGui)
	if not scrollingFrame then
		warn("[BattlePassPopup] Container.CanvasGroup.ScrollingFrame 없음")
		return false
	end

	local template = findBattlePassItemTemplate(scrollingFrame)
	if not template then
		warn("[BattlePassPopup] Container.CanvasGroup.ScrollingFrame.BattlePassItem 없음")
		return false
	end

	template.Visible = false
	itemPool = {}

	for _, level in BattlePassHelper.getLevelIndices() do
		local cloneInst = template:Clone()
		cloneInst.Name = "BattlePassItem_" .. tostring(level)
		cloneInst.Visible = true
		cloneInst.LayoutOrder = level
		cloneInst.Parent = scrollingFrame
		table.insert(itemPool, cloneInst)
	end

	itemPoolBuilt = true
	return #itemPool > 0
end

local function canClaimTrackLevel(
	level: number,
	playerLevel: number,
	claimedLevel: number,
	ownsPremiumPass: boolean,
	track: BattlePassRewardTrack
): boolean
	if level > playerLevel then
		return false
	end
	if level <= claimedLevel then
		return false
	end
	if track == "premium" and not ownsPremiumPass then
		return false
	end
	return true
end

local function getTrackLevelState(
	level: number,
	playerLevel: number,
	claimedLevel: number,
	ownsPremiumPass: boolean,
	track: BattlePassRewardTrack
): "claimed" | "claimable" | "locked"
	if level <= claimedLevel then
		return "claimed"
	end
	if canClaimTrackLevel(level, playerLevel, claimedLevel, ownsPremiumPass, track) then
		return "claimable"
	end
	return "locked"
end

local function applyRewardButton(btnReward: GuiButton, reward: Reward, icons: { [string]: ImageLabel? })
	btnReward.Active = true
	if btnReward:IsA("GuiObject") then
		local gui = btnReward :: GuiObject
		gui.ZIndex = math.max(gui.ZIndex, 2)
	end
	pcall(function()
		(btnReward :: any).Interactable = true
	end)

	local rewardIconInst = btnReward:FindFirstChild("RewardIcon")
	if rewardIconInst and rewardIconInst:IsA("ImageLabel") then
		applyRewardIcon(rewardIconInst :: ImageLabel, reward, icons)
	else
		warn("[BattlePassPopup] BtnReward.RewardIcon (ImageLabel) 없음")
	end

	local rewardCntInst = btnReward:FindFirstChild("RewardCnt")
	if rewardCntInst and rewardCntInst:IsA("TextLabel") then
		local rewardCnt = rewardCntInst :: TextLabel
		rewardCnt.Text = formatRewardCountText(reward)
	else
		warn("[BattlePassPopup] BtnReward.RewardCnt (TextLabel) 없음")
	end
end

local function applyRewardSlot(
	rewardFrame: Instance,
	reward: Reward,
	state: "claimed" | "claimable" | "locked",
	icons: { [string]: ImageLabel? }
)
	local claimedInst = rewardFrame:FindFirstChild("Claimed")
	if claimedInst and claimedInst:IsA("GuiObject") then
		(claimedInst :: GuiObject).Visible = state == "claimed"
	end

	local claimEffectInst = rewardFrame:FindFirstChild("ClaimEffect")
	if claimEffectInst and claimEffectInst:IsA("GuiObject") then
		(claimEffectInst :: GuiObject).Visible = state == "claimable"
	end

	local btnRewardInst = rewardFrame:FindFirstChild("BtnReward")
	if btnRewardInst and btnRewardInst:IsA("GuiButton") then
		applyRewardButton(btnRewardInst :: GuiButton, reward, icons)
	else
		warn("[BattlePassPopup]", rewardFrame.Name, "BtnReward (GuiButton) 없음")
	end
end

local function applyBattlePassItemRow(
	itemFrame: GuiObject,
	level: number,
	snapshot: BattlePassSnapshot,
	icons: { [string]: ImageLabel? }
)
	local levelDef = BattlePassHelper.getLevelDefinition(level)
	if not levelDef then
		return
	end

	local passLevel = itemFrame:FindFirstChild("PassLevel")
	local txtPassLevelInst = passLevel and passLevel:FindFirstChild("TxtPassLevel")
	if txtPassLevelInst and txtPassLevelInst:IsA("TextLabel") then
		local txtPassLevel = txtPassLevelInst :: TextLabel
		txtPassLevel.Text = tostring(level)
	else
		warn("[BattlePassPopup]", itemFrame.Name, "PassLevel.TxtPassLevel 없음")
	end

	local freeReward = itemFrame:FindFirstChild("FreeReward")
	if freeReward then
		local freeState = getTrackLevelState(
			level,
			snapshot.level,
			snapshot.freeClaimedLevel,
			snapshot.ownsPremiumPass,
			"free"
		)
		applyRewardSlot(freeReward, levelDef.freeReward, freeState, icons)
	else
		warn("[BattlePassPopup]", itemFrame.Name, "FreeReward 없음")
	end

	local premiumReward = itemFrame:FindFirstChild("PremiumReward")
	if premiumReward then
		local premiumState = getTrackLevelState(
			level,
			snapshot.level,
			snapshot.premiumClaimedLevel,
			snapshot.ownsPremiumPass,
			"premium"
		)
		applyRewardSlot(premiumReward, levelDef.premiumReward, premiumState, icons)

		local premiumBtnInst = premiumReward:FindFirstChild("BtnReward")
		local lockIconInst = premiumBtnInst and premiumBtnInst:FindFirstChild("LockIcon")
		if lockIconInst and lockIconInst:IsA("GuiObject") then
			(lockIconInst :: GuiObject).Visible = not snapshot.ownsPremiumPass
		end
	else
		warn("[BattlePassPopup]", itemFrame.Name, "PremiumReward 없음")
	end
end

local function rewardsToPopupEntries(rewards: { Reward }): { RewardPopupEntry }
	local aggregated: { [string]: number } = {}
	for _, reward in rewards do
		if reward.rewardType == "Currency" then
			aggregated[reward.currencyType] = (aggregated[reward.currencyType] or 0) + reward.amount
		end
	end

	local entries: { RewardPopupEntry } = {}
	for currencyType, amount in aggregated do
		table.insert(entries, {
			currencyType = currencyType :: "Gem" | "Gold" | "BattlePassPoint",
			amount = amount,
		})
	end
	return entries
end

local function applyRewardTrack(rootGui: GuiObject, snapshot: BattlePassSnapshot)
	local icons = resolveCurrencyIcons()
	if not icons then
		return
	end
	if not ensureItemPool(rootGui) then
		return
	end

	for index, level in BattlePassHelper.getLevelIndices() do
		local itemFrame = itemPool[index]
		if itemFrame then
			applyBattlePassItemRow(itemFrame, level, snapshot, icons)
		end
	end
end

local function applyPremiumMaxReward(rootGui: GuiObject, snapshot: BattlePassSnapshot)
	local container = rootGui:FindFirstChild("Container")
	local premium = container and container:FindFirstChild("Premium")
	if not premium then
		return
	end

	local reward = BattlePassHelper.getMaxLevelPremiumReward()
	if reward.rewardType ~= "Costume" then
		return
	end

	local claimed = snapshot.maxLevelPremiumRewardClaimed == true
	local claimable = BattlePassHelper.canClaimMaxLevelPremiumReward(
		snapshot.level,
		snapshot.ownsPremiumPass,
		claimed
	)

	local claimedInst = premium:FindFirstChild("Claimed")
	if claimedInst and claimedInst:IsA("GuiObject") then
		(claimedInst :: GuiObject).Visible = claimed
	end

	local claimEffectInst = premium:FindFirstChild("ClaimEffect")
	if claimEffectInst and claimEffectInst:IsA("GuiObject") then
		(claimEffectInst :: GuiObject).Visible = claimable
	end

	local lockIconInst = premium:FindFirstChild("LockIcon")
	if lockIconInst and lockIconInst:IsA("GuiObject") then
		(lockIconInst :: GuiObject).Visible = not snapshot.ownsPremiumPass
	end

	local claimButtonInst = premium:FindFirstChild("ClaimButton")
	if claimButtonInst and claimButtonInst:IsA("GuiButton") then
		local claimButton = claimButtonInst :: GuiButton
		claimButton.Active = true
		pcall(function()
			(claimButton :: any).Interactable = true
		end)

		local txtRewardNameInst = claimButton:FindFirstChild("TxtRewardName")
		if txtRewardNameInst and txtRewardNameInst:IsA("TextLabel") then
			local txtRewardName = txtRewardNameInst :: TextLabel
			txtRewardName.Text = StringHelper.get(reward.id, LOCALE)
		end
	end

	local rewardIconInst = premium:FindFirstChild("RewardIcon")
	if rewardIconInst and rewardIconInst:IsA("ImageLabel") then
		local iconAssetId = resolveCostumeIconAssetIdById()[reward.id]
		if iconAssetId then
			(rewardIconInst :: ImageLabel).ImageContent = Content.fromUri(iconAssetId)
		else
			warn("[BattlePassPopup] CostumeData에 iconAssetId 없음:", reward.id)
		end
	end
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

local function getBattlePassPopupRoot(): GuiObject?
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

local function getBuyButton(rootGui: GuiObject): GuiButton?
	local container = rootGui:FindFirstChild("Container")
	local leftPanel = container and container:FindFirstChild("LeftPanel")
	local btnInst = leftPanel and leftPanel:FindFirstChild("BtnBuy")
	if btnInst and btnInst:IsA("GuiButton") then
		return btnInst :: GuiButton
	end
	return nil
end

local function findTxtRemainTime(rootGui: GuiObject): TextLabel?
	local container = rootGui:FindFirstChild("Container")
	local txtInst = container and container:FindFirstChild("TxtRemainTime")
	if txtInst and txtInst:IsA("TextLabel") then
		return txtInst :: TextLabel
	end
	return nil
end

local function findPassInfoGauge(rootGui: GuiObject): Instance?
	local container = rootGui:FindFirstChild("Container")
	local passInfo = container and container:FindFirstChild("PassInfo")
	local gauge = passInfo and passInfo:FindFirstChild("Gauge")
	return gauge
end

local function getJumpLevelButton(rootGui: GuiObject): GuiButton?
	local container = rootGui:FindFirstChild("Container")
	local passInfo = container and container:FindFirstChild("PassInfo")
	local btnInst = passInfo and passInfo:FindFirstChild("BtnJumpLevel")
	if btnInst and btnInst:IsA("GuiButton") then
		return btnInst :: GuiButton
	end
	return nil
end

local function applyPassInfoProgress(gauge: Instance, snapshot: BattlePassSnapshot)
	local passLevel = gauge:FindFirstChild("PassLevel")
	local txtPassLevelInst = passLevel and passLevel:FindFirstChild("TxtPassLevel")
	if txtPassLevelInst and txtPassLevelInst:IsA("TextLabel") then
		local txtPassLevel = txtPassLevelInst :: TextLabel
		txtPassLevel.Text = tostring(snapshot.level)
	else
		warn("[BattlePassPopup] PassInfo.Gauge.PassLevel.TxtPassLevel 없음")
	end

	local xpBar = gauge:FindFirstChild("XPBar")
	if not xpBar then
		warn("[BattlePassPopup] PassInfo.Gauge.XPBar 없음")
		return
	end

	local fillInst = xpBar:FindFirstChild("Fill")
	if fillInst and fillInst:IsA("GuiObject") then
		local fill = fillInst :: GuiObject
		local goal = math.max(1, snapshot.xpRequiredForNextLevel)
		local current = math.clamp(snapshot.xp, 0, goal)
		local ratio = if snapshot.isMaxLevel then 1 else math.clamp(current / goal, 0, 1)
		fill.Size = UDim2.new(ratio, 0, fill.Size.Y.Scale, fill.Size.Y.Offset)
	else
		warn("[BattlePassPopup] PassInfo.Gauge.XPBar.Fill 없음")
	end

	local txtProgressInst = xpBar:FindFirstChild("TxtProgress")
	if txtProgressInst and txtProgressInst:IsA("TextLabel") then
		local goal = math.max(1, snapshot.xpRequiredForNextLevel)
		local current = math.clamp(snapshot.xp, 0, goal)
		local txtProgress = txtProgressInst :: TextLabel
		txtProgress.Text = string.format("%d/%d", current, goal)
	else
		warn("[BattlePassPopup] PassInfo.Gauge.XPBar.TxtProgress 없음")
	end

	local btnJumpLevelInst = gauge:FindFirstChild("BtnJumpLevel")
	if btnJumpLevelInst and btnJumpLevelInst:IsA("GuiButton") then
		(btnJumpLevelInst :: GuiButton).Visible = not snapshot.isMaxLevel
	end
end

local function applyPassInfo(rootGui: GuiObject, snapshot: BattlePassSnapshot)
	local gauge = findPassInfoGauge(rootGui)
	if not gauge then
		warn("[BattlePassPopup] Container.PassInfo.Gauge 없음")
		return
	end
	applyPassInfoProgress(gauge, snapshot)
end

local function fetchBattlePassSnapshot(): BattlePassSnapshot
	return BattlePassHelper.fetchSnapshot() or BattlePassHelper.buildProgressSnapshot(0, 0)
end

local function refreshBattlePassUi(rootGui: GuiObject, snapshot: BattlePassSnapshot?)
	local resolvedSnapshot = snapshot or fetchBattlePassSnapshot()
	applyPassInfo(rootGui, resolvedSnapshot)
	applyRewardTrack(rootGui, resolvedSnapshot)
	applyPremiumMaxReward(rootGui, resolvedSnapshot)
end

local function claimTrackInto(track: BattlePassRewardTrack, collected: { Reward }): BattlePassSnapshot?
	local result = BattlePassHelper.requestClaimRewards(track)
	if not result or not result.ok then
		if result and result.errorMessage then
			warn("[BattlePassPopup] 보상 수령 실패:", track, result.errorMessage)
		end
		return nil
	end
	if result.rewards then
		for _, reward in result.rewards do
			table.insert(collected, reward)
		end
	end
	return result.snapshot
end

local function onRewardClaimClicked(track: BattlePassRewardTrack, level: number)
	if isClaiming then
		return
	end

	local rootGui = getBattlePassPopupRoot()
	if not rootGui then
		return
	end

	local snapshot = fetchBattlePassSnapshot()
	local claimedLevel = if track == "free" then snapshot.freeClaimedLevel else snapshot.premiumClaimedLevel
	local state = getTrackLevelState(level, snapshot.level, claimedLevel, snapshot.ownsPremiumPass, track)

	local levelDef = BattlePassHelper.getLevelDefinition(level)
	local reward = if levelDef then (if track == "free" then levelDef.freeReward else levelDef.premiumReward) else nil
	if reward and reward.rewardType == "Item" and state == "locked" then
		ItemInfoPopup.open(reward.itemType)
		return
	end

	if state ~= "claimable" then
		return
	end

	local freeClaimable = snapshot.level > snapshot.freeClaimedLevel
	local premiumClaimable = snapshot.ownsPremiumPass and snapshot.level > snapshot.premiumClaimedLevel
	if not freeClaimable and not premiumClaimable then
		return
	end

	isClaiming = true
	local collectedRewards: { Reward } = {}
	local latestSnapshot: BattlePassSnapshot? = nil

	if freeClaimable then
		latestSnapshot = claimTrackInto("free", collectedRewards) or latestSnapshot
	end
	if premiumClaimable then
		latestSnapshot = claimTrackInto("premium", collectedRewards) or latestSnapshot
	end
	isClaiming = false

	refreshBattlePassUi(rootGui, latestSnapshot)
	BattlePassClient.refreshNotification()

	if #collectedRewards > 0 then
		local popupEntries = rewardsToPopupEntries(collectedRewards)
		if #popupEntries > 0 then
			task.defer(function()
				RewardPopup.open(RewardPopup.TitleType.Reward, popupEntries)
			end)
		end
	end
end

local function onPremiumMaxRewardClaimClicked()
	local rootGui = getBattlePassPopupRoot()
	if not rootGui then
		return
	end

	local snapshot = fetchBattlePassSnapshot()
	if not BattlePassHelper.canClaimMaxLevelPremiumReward(
		snapshot.level,
		snapshot.ownsPremiumPass,
		snapshot.maxLevelPremiumRewardClaimed
	) then
		return
	end

	warn("[BattlePassPopup] 최대 레벨 프리미엄 보상 수령은 아직 구현되지 않음")
end

local function bindRewardClaimButtons(rootGui: GuiObject)
	if rewardButtonsBound then
		return
	end
	if not ensureItemPool(rootGui) then
		return
	end

	for index, level in BattlePassHelper.getLevelIndices() do
		local itemFrame = itemPool[index]
		if not itemFrame then
			continue
		end

		local freeReward = itemFrame:FindFirstChild("FreeReward")
		local freeBtnInst = freeReward and freeReward:FindFirstChild("BtnReward")
		if freeBtnInst and freeBtnInst:IsA("GuiButton") then
			local freeBtn = freeBtnInst :: GuiButton
			prepareClickableButton(freeBtn)
			freeBtn.Activated:Connect(function()
				onRewardClaimClicked("free", level)
			end)
		end

		local premiumReward = itemFrame:FindFirstChild("PremiumReward")
		local premiumBtnInst = premiumReward and premiumReward:FindFirstChild("BtnReward")
		if premiumBtnInst and premiumBtnInst:IsA("GuiButton") then
			local premiumBtn = premiumBtnInst :: GuiButton
			prepareClickableButton(premiumBtn)
			premiumBtn.Activated:Connect(function()
				onRewardClaimClicked("premium", level)
			end)
		end
	end

	rewardButtonsBound = true
end

local function bindPremiumMaxRewardButton(rootGui: GuiObject, connections: { RBXScriptConnection })
	local container = rootGui:FindFirstChild("Container")
	local premium = container and container:FindFirstChild("Premium")
	local claimButtonInst = premium and premium:FindFirstChild("ClaimButton")
	if not (claimButtonInst and claimButtonInst:IsA("GuiButton")) then
		return
	end

	local claimButton = claimButtonInst :: GuiButton
	prepareClickableButton(claimButton)
	table.insert(connections, claimButton.Activated:Connect(onPremiumMaxRewardClaimClicked))
end

local function startRemainTimeUpdater(
	rootGui: GuiObject,
	connections: { RBXScriptConnection },
	isClosed: () -> boolean
)
	local txtRemainTime = findTxtRemainTime(rootGui)
	if not txtRemainTime then
		warn("[BattlePassPopup] Container.TxtRemainTime 없음")
		return
	end

	local function updateRemainTime()
		local remainingSec = BattlePassHelper.getSecondsUntilSeasonEnd()
		txtRemainTime.Text = StringHelper.formatRemainTimeLabel(remainingSec, LOCALE)
	end

	updateRemainTime()

	local elapsed = 0
	table.insert(
		connections,
		RunService.Heartbeat:Connect(function(dt: number)
			if isClosed() then
				return
			end
			elapsed += dt
			if elapsed < REMAIN_TIME_UPDATE_INTERVAL then
				return
			end
			elapsed = 0
			updateRemainTime()
		end)
	)
end

local function formatRobuxPrice(priceInRobux: number): string
	return tostring(math.max(0, math.floor(priceInRobux)))
end

local function fetchPassPrice(): number?
	if cachedPassPrice then
		return cachedPassPrice
	end

	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfoAsync(BattlePassHelper.getPremiumGamePassId(), Enum.InfoType.GamePass)
	end)
	if not ok or typeof(info) ~= "table" then
		warn("[BattlePassPopup] GetProductInfoAsync 실패 passId=", BattlePassHelper.getPremiumGamePassId(), info)
		return nil
	end

	local price = info.PriceInRobux
	if typeof(price) ~= "number" or price ~= price then
		warn("[BattlePassPopup] GamePass 가격 없음 passId=", BattlePassHelper.getPremiumGamePassId())
		return nil
	end

	cachedPassPrice = math.max(0, math.floor(price))
	return cachedPassPrice
end

local function checkOwnsPremiumPass(): boolean
	if cachedOwnsPass ~= nil then
		return cachedOwnsPass
	end

	local fromAttr = BattlePassHelper.getOwnsPremiumPassFromAttribute()
	if fromAttr ~= nil then
		cachedOwnsPass = fromAttr
		return fromAttr
	end

	cachedOwnsPass = BattlePassHelper.fetchOwnsPremiumPass()
	return cachedOwnsPass :: boolean
end

local function applyBuyButtonState(rootGui: GuiObject)
	local btnBuy = getBuyButton(rootGui)
	if not btnBuy then
		warn("[BattlePassPopup] Container.LeftPanel.BtnBuy 없음")
		return
	end

	local ownsPass = checkOwnsPremiumPass()
	btnBuy.Visible = not ownsPass
	if ownsPass then
		return
	end

	local txtPriceInst = btnBuy:FindFirstChild("TxtPrice")
	if txtPriceInst and txtPriceInst:IsA("TextLabel") then
		local txtPrice = txtPriceInst :: TextLabel
		local price = fetchPassPrice()
		txtPrice.Text = formatRobuxPrice(price or 199)
	end
end

local function refreshOwnsPremiumPassAsync(rootGui: GuiObject)
	task.spawn(function()
		cachedOwnsPass = nil
		cachedOwnsPass = BattlePassHelper.fetchOwnsPremiumPass()
		applyBuyButtonState(rootGui)
		if activeSession then
			refreshBattlePassUi(rootGui)
		end
		BattlePassClient.refreshNotification()
	end)
end

local function refreshBuyButtonState(rootGui: GuiObject)
	refreshOwnsPremiumPassAsync(rootGui)
end

local function promptPremiumPassPurchase()
	if isPurchasePromptOpen then
		return
	end
	if checkOwnsPremiumPass() then
		return
	end

	isPurchasePromptOpen = true
	local ok, err = pcall(function()
		MarketplaceService:PromptGamePassPurchase(Players.LocalPlayer, BattlePassHelper.getPremiumGamePassId())
	end)
	if not ok then
		warn("[BattlePassPopup] PromptGamePassPurchase 실패 passId=", BattlePassHelper.getPremiumGamePassId(), err)
		isPurchasePromptOpen = false
	end
end

local function bindBuyButton(rootGui: GuiObject, connections: { RBXScriptConnection })
	local btnBuy = getBuyButton(rootGui)
	if not btnBuy then
		warn("[BattlePassPopup] Container.LeftPanel.BtnBuy 없음")
		return
	end

	prepareClickableButton(btnBuy)
	table.insert(connections, btnBuy.Activated:Connect(promptPremiumPassPurchase))
end

local function promptJumpLevelPurchase()
	if isJumpLevelPromptOpen then
		return
	end

	isJumpLevelPromptOpen = true
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(Players.LocalPlayer, BattlePassHelper.getJumpLevelProductId())
	end)
	if not ok then
		warn("[BattlePassPopup] PromptProductPurchase 실패 productId=", BattlePassHelper.getJumpLevelProductId(), err)
		isJumpLevelPromptOpen = false
	end
end

local function bindJumpLevelButton(rootGui: GuiObject, connections: { RBXScriptConnection })
	local btnJumpLevel = getJumpLevelButton(rootGui)
	if not btnJumpLevel then
		warn("[BattlePassPopup] Container.PassInfo.Gauge.BtnJumpLevel 없음")
		return
	end

	prepareClickableButton(btnJumpLevel)
	table.insert(connections, btnJumpLevel.Activated:Connect(promptJumpLevelPurchase))
end

local function onGamePassPurchaseFinished(player: Player, passId: number, _wasPurchased: boolean)
	if player ~= Players.LocalPlayer then
		return
	end
	if passId ~= BattlePassHelper.getPremiumGamePassId() then
		return
	end

	isPurchasePromptOpen = false

	local rootGui = getBattlePassPopupRoot()
	if rootGui then
		refreshOwnsPremiumPassAsync(rootGui)
	end
end

local function onOwnsPassAttributeChanged()
	cachedOwnsPass = BattlePassHelper.getOwnsPremiumPassFromAttribute()
	local rootGui = getBattlePassPopupRoot()
	if rootGui and activeSession then
		applyBuyButtonState(rootGui)
		refreshBattlePassUi(rootGui)
	end
	BattlePassClient.refreshNotification()
end

function BattlePassPopup.open(skipEntranceAnimation: boolean?)
	if activeSession then
		return
	end

	local rootGui = getBattlePassPopupRoot()
	if not rootGui then
		warn("[BattlePassPopup] Content.BattlePassPopup 없음")
		return
	end
	StringBinder.applySubtreeOnce(rootGui)

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[BattlePassPopup] Content 없음")
		return
	end

	local top = rootGui:FindFirstChild("Top")
	local closeInst = top and top:FindFirstChild("CloseButton")
	if not (closeInst and closeInst:IsA("GuiButton")) then
		warn("[BattlePassPopup] Top.CloseButton 없음")
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
		ItemInfoPopup.close()
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

	ItemInfoPopup.close()
	rootGui.Visible = true
	if pushOptions.playEntranceAnimation then
		PopupManager.playBounceEntrance(rootGui)
	end

	prepareClickableButton(closeBtn)
	table.insert(connections, closeBtn.Activated:Connect(close))
	bindBuyButton(rootGui, connections)
	bindJumpLevelButton(rootGui, connections)
	bindRewardClaimButtons(rootGui)
	bindPremiumMaxRewardButton(rootGui, connections)
	refreshBuyButtonState(rootGui)
	refreshBattlePassUi(rootGui)
	BattlePassClient.refreshNotification()
	startRemainTimeUpdater(rootGui, connections, function()
		return closed
	end)

	activeSession = { close = close }
end

function BattlePassPopup.close()
	if activeSession then
		activeSession.close()
	end
end

local function bindPurchaseListener()
	if purchaseFinishedConnection then
		return
	end

	purchaseFinishedConnection = MarketplaceService.PromptGamePassPurchaseFinished:Connect(onGamePassPurchaseFinished)
end

local function bindOwnsPassAttributeListener()
	if ownsPassAttributeConnection then
		return
	end

	local player = Players.LocalPlayer
	ownsPassAttributeConnection = player:GetAttributeChangedSignal(BattlePassHelper.OWNS_PREMIUM_PASS_ATTRIBUTE)
		:Connect(onOwnsPassAttributeChanged)
end

local function onJumpLevelPurchaseGranted(payload: any)
	if typeof(payload) ~= "table" or payload.productId ~= BattlePassHelper.getJumpLevelProductId() then
		return
	end

	isJumpLevelPromptOpen = false
	local rootGui = getBattlePassPopupRoot()
	if rootGui and activeSession then
		refreshBattlePassUi(rootGui)
	end
end

local function onJumpLevelProductPurchaseFinished(_userId: number, productId: number, _wasPurchased: boolean)
	if productId == BattlePassHelper.getJumpLevelProductId() then
		isJumpLevelPromptOpen = false
	end
end

local function bindJumpLevelPurchaseListeners()
	if jumpLevelPurchaseGrantedConnection then
		return
	end

	local purchaseGrantedEvent = ReplicatedStorage:WaitForChild(ShopHelper.PURCHASE_GRANTED_EVENT_NAME)
	jumpLevelPurchaseGrantedConnection = (purchaseGrantedEvent :: RemoteEvent).OnClientEvent:Connect(
		onJumpLevelPurchaseGranted
	)
	jumpLevelPromptFinishedConnection = MarketplaceService.PromptProductPurchaseFinished:Connect(
		onJumpLevelProductPurchaseFinished
	)
end

function BattlePassPopup.init()
	if initialized then
		return
	end
	initialized = true
	bindPurchaseListener()
	bindOwnsPassAttributeListener()
	bindJumpLevelPurchaseListeners()
	print("[BattlePassPopup] 초기화 완료")
end

return BattlePassPopup
