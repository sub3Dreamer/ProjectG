--[[
	RewardPopup (lobby client)

	GUI 트리: PopupScreenGui.Content.RewardPopup (CanvasGroup)
		BackgroundButton — 클릭 시 닫기
		Container.Rewards (Frame, UIListLayout)
			Reward (Frame) — 보상 1개 단위 템플릿
				RewardIcon, RewardCnt
		Container.RibbonRoot — Ribbon_Reward / Ribbon_Purchase

	열기:
		RewardPopup.open(titleType, rewards, onClose?)
		RewardPopup.open(titleType, currencyType, amount, onClose?) — 단일 보상 (하위 호환)

	RewardIcon: ReplicatedStorage.Client.Currency.{Gem,Gold,BattlePassPoint} 의 이미지 속성만 복사.
	보상 N개: Reward 템플릿 Clone 풀 + LayoutOrder, 미사용 슬롯 Visible = false.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)
local SoundManager = require(Shared.Managers.SoundManager)
local Types = require(Shared.Types)
local StringBinder = require(Shared.Helpers.StringBinder)

local RewardPopup = {}

RewardPopup.TitleType = {
	Reward = "Reward",
	Purchase = "Purchase",
}

export type RewardEntry = {
	currencyType: Types.CurrencyType?,
	customImage: string?, -- 통화 아이콘 대신 임의 이미지(예: 코스튬 iconAssetId)를 그대로 쓰고 싶을 때
	amount: number,
}

local POPUP_ROOT_NAME = "RewardPopup"
local REWARDS_FRAME_NAME = "Rewards"
local REWARD_SLOT_NAME = "Reward"
local RIBBON_ROOT_NAME = "RibbonRoot"
local RIBBON_REWARD_NAME = "Ribbon_Reward"
local RIBBON_PURCHASE_NAME = "Ribbon_Purchase"
local CURRENCY_FOLDER_PATH = { "Client", "Currency" }
local CURRENCY_ICON_SIZE_SCALE = 0.5 -- 기존 통화 아이콘 크기 (그대로 유지)
local CUSTOM_ICON_SIZE_SCALE = 1 -- 코스튬 등 커스텀 아이콘은 꽉 채워서 표시

type TitleType = "Reward" | "Purchase"
type CurrencyType = Types.CurrencyType

local initialized = false
local activeSession: { close: () -> () }? = nil
local currencyIcons: { [CurrencyType]: ImageLabel? }? = nil

local rewardTemplate: Frame? = nil
local rewardClones: { Frame } = {}

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

local function getRewardPopupRoot(): GuiObject?
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

local function resolveCurrencyIcons(): { [CurrencyType]: ImageLabel? }?
	if currencyIcons then
		return currencyIcons
	end

	local folder: Instance = ReplicatedStorage
	for _, name in CURRENCY_FOLDER_PATH do
		local child = folder:FindFirstChild(name)
		if not child then
			warn("[RewardPopup] ReplicatedStorage." .. table.concat(CURRENCY_FOLDER_PATH, ".") .. " 없음")
			return nil
		end
		folder = child
	end

	local icons: { [CurrencyType]: ImageLabel? } = {}
	for _, currencyType in Types.CURRENCY_TYPES do
		local iconInst = folder:FindFirstChild(currencyType)
		local icon = if iconInst and iconInst:IsA("ImageLabel") then iconInst :: ImageLabel else nil
		if not icon then
			warn("[RewardPopup] Client.Currency." .. currencyType .. " (ImageLabel) 없음")
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

local function formatRewardCountText(amount: number): string
	return tostring(math.max(0, math.floor(amount)))
end

local function normalizeTitleType(raw: any): TitleType?
	if raw == RewardPopup.TitleType.Reward or raw == "Reward" then
		return "Reward"
	end
	if raw == RewardPopup.TitleType.Purchase or raw == "Purchase" then
		return "Purchase"
	end
	return nil
end

local function normalizeAmount(raw: any): number?
	if typeof(raw) ~= "number" or raw ~= raw then
		return nil
	end
	local amount = math.floor(raw)
	if amount <= 0 then
		return nil
	end
	return amount
end

local function normalizeRewardEntry(raw: any): RewardEntry?
	if typeof(raw) ~= "table" then
		return nil
	end

	if typeof(raw.customImage) == "string" and raw.customImage ~= "" then
		local amount = if raw.amount == nil then 1 else normalizeAmount(raw.amount)
		if not amount then
			return nil
		end
		return {
			customImage = raw.customImage,
			amount = amount,
		}
	end

	local currencyType = Types.normalizeCurrencyType(raw.currencyType)
	local amount = normalizeAmount(raw.amount)
	if not currencyType or not amount then
		return nil
	end
	return {
		currencyType = currencyType,
		amount = amount,
	}
end

local function normalizeRewards(raw: any): { RewardEntry }?
	if typeof(raw) ~= "table" then
		return nil
	end

	if raw.currencyType ~= nil or raw.customImage ~= nil then
		local single = normalizeRewardEntry(raw)
		if not single then
			return nil
		end
		return { single }
	end

	local rewards: { RewardEntry } = {}
	for _, entryRaw in raw do
		local entry = normalizeRewardEntry(entryRaw)
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

local function resolveOpenArgs(
	arg2: any,
	arg3: any?,
	arg4: (() -> ())?
): ({ RewardEntry }?, (() -> ())?)
	if typeof(arg2) == "string" then
		local currencyType = Types.normalizeCurrencyType(arg2)
		local amount = normalizeAmount(arg3)
		if not currencyType or not amount then
			return nil, arg4
		end
		return {
			{
				currencyType = currencyType,
				amount = amount,
			},
		}, arg4
	end

	local rewards = normalizeRewards(arg2)
	return rewards, arg3 :: (() -> ())?
end

local function ensureRewardTemplate(container: Instance): boolean
	if rewardTemplate then
		return true
	end

	local rewardsFrameInst = container:FindFirstChild(REWARDS_FRAME_NAME)
	if not (rewardsFrameInst and rewardsFrameInst:IsA("GuiObject")) then
		warn("[RewardPopup] Container.Rewards 없음")
		return false
	end

	local templateInst = rewardsFrameInst:FindFirstChild(REWARD_SLOT_NAME)
	if not (templateInst and templateInst:IsA("GuiObject")) then
		warn("[RewardPopup] Container.Rewards.Reward 없음")
		return false
	end

	local template = templateInst :: Frame
	template.Visible = false
	template.LayoutOrder = 0
	rewardTemplate = template
	return true
end

local function getRewardSlot(index: number): Frame?
	local template = rewardTemplate
	if not template then
		return nil
	end

	if index == 1 then
		return template
	end

	local cloneIndex = index - 1
	while #rewardClones < cloneIndex do
		local clone = template:Clone()
		clone.Name = REWARD_SLOT_NAME .. tostring(#rewardClones + 2)
		clone.Parent = template.Parent
		table.insert(rewardClones, clone)
	end

	return rewardClones[cloneIndex]
end

local function hideAllRewardSlots()
	if rewardTemplate then
		rewardTemplate.Visible = false
	end
	for _, clone in rewardClones do
		clone.Visible = false
	end
end

local function applyTitleRibbon(rootGui: GuiObject, titleType: TitleType): boolean
	local container = rootGui:FindFirstChild("Container")
	if not container then
		warn("[RewardPopup] Container 없음")
		return false
	end

	local ribbonRoot = container:FindFirstChild(RIBBON_ROOT_NAME)
	if not ribbonRoot then
		warn("[RewardPopup] RibbonRoot 없음")
		return false
	end

	local ribbonRewardInst = ribbonRoot:FindFirstChild(RIBBON_REWARD_NAME)
	local ribbonPurchaseInst = ribbonRoot:FindFirstChild(RIBBON_PURCHASE_NAME)
	if not (ribbonRewardInst and ribbonRewardInst:IsA("GuiObject")) then
		warn("[RewardPopup] Ribbon_Reward 없음")
		return false
	end
	if not (ribbonPurchaseInst and ribbonPurchaseInst:IsA("GuiObject")) then
		warn("[RewardPopup] Ribbon_Purchase 없음")
		return false
	end

	local showReward = titleType == "Reward"
	local ribbonReward = ribbonRewardInst :: GuiObject
	local ribbonPurchase = ribbonPurchaseInst :: GuiObject
	ribbonReward.Visible = showReward
	ribbonPurchase.Visible = not showReward
	return true
end

local function applyRewardSlot(slot: Frame, entry: RewardEntry, icons: { [CurrencyType]: ImageLabel? }): boolean
	local rewardIconInst = slot:FindFirstChild("RewardIcon")
	local rewardCntInst = slot:FindFirstChild("RewardCnt")
	if not (rewardIconInst and rewardIconInst:IsA("ImageLabel")) then
		warn("[RewardPopup]", slot.Name, "RewardIcon (ImageLabel) 없음")
		return false
	end
	if not (rewardCntInst and rewardCntInst:IsA("TextLabel")) then
		warn("[RewardPopup]", slot.Name, "RewardCnt (TextLabel) 없음")
		return false
	end

	local rewardIcon = rewardIconInst :: ImageLabel
	local rewardCnt = rewardCntInst :: TextLabel

	if entry.customImage then
		rewardIcon.Image = entry.customImage
		rewardIcon.ImageRectOffset = Vector2.new(0, 0)
		rewardIcon.ImageRectSize = Vector2.new(0, 0)
		rewardIcon.Size = UDim2.fromScale(CUSTOM_ICON_SIZE_SCALE, CUSTOM_ICON_SIZE_SCALE)
		local aspectConstraint = rewardIcon:FindFirstChildOfClass("UIAspectRatioConstraint")
		if aspectConstraint then
			aspectConstraint.AspectRatio = 1
		end
		rewardCnt.Visible = false
		return true
	end

	local sourceIcon = entry.currencyType and icons[entry.currencyType]
	if not sourceIcon then
		warn("[RewardPopup] currencyType 아이콘 없음:", entry.currencyType)
		return false
	end

	applyImageLabelImageProperties(sourceIcon, rewardIcon)
	rewardIcon.Size = UDim2.fromScale(CURRENCY_ICON_SIZE_SCALE, CURRENCY_ICON_SIZE_SCALE)
	rewardCnt.Visible = true
	rewardCnt.Text = formatRewardCountText(entry.amount)
	return true
end

local function applyRewards(rootGui: GuiObject, rewards: { RewardEntry }): boolean
	local icons = resolveCurrencyIcons()
	if not icons then
		return false
	end

	local container = rootGui:FindFirstChild("Container")
	if not container then
		warn("[RewardPopup] Container 없음")
		return false
	end
	if not ensureRewardTemplate(container) then
		return false
	end

	hideAllRewardSlots()

	for index, entry in ipairs(rewards) do
		local slot = getRewardSlot(index)
		if not slot then
			warn("[RewardPopup] 슬롯 확보 실패:", index)
			return false
		end
		slot.LayoutOrder = index
		slot.Visible = true
		if not applyRewardSlot(slot, entry, icons) then
			return false
		end
	end

	return true
end

function RewardPopup.open(titleType: any, arg2: any, arg3: any?, arg4: (() -> ())?)
	if activeSession then
		activeSession.close()
	end

	local normalizedRewards, onClose = resolveOpenArgs(arg2, arg3, arg4)

	local function finishOnClose()
		if onClose then
			onClose()
		end
	end

	local normalizedTitleType = normalizeTitleType(titleType)
	if not normalizedTitleType or not normalizedRewards then
		warn("[RewardPopup] 잘못된 인자:", titleType, arg2, arg3)
		finishOnClose()
		return
	end

	local rootGui = getRewardPopupRoot()
	if not rootGui then
		warn("[RewardPopup] Content.RewardPopup 없음")
		finishOnClose()
		return
	end
	StringBinder.applySubtreeOnce(rootGui)

	local bgBtnInst = rootGui:FindFirstChild("BackgroundButton")
	if not (bgBtnInst and bgBtnInst:IsA("GuiButton")) then
		warn("[RewardPopup] BackgroundButton 없음")
		finishOnClose()
		return
	end
	local backgroundBtn = bgBtnInst :: GuiButton

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[RewardPopup] Content 없음")
		finishOnClose()
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
		hideAllRewardSlots()
		rootGui.Visible = wasRootVis
		contentGui.Active = prevContentActive
		rootGui.Active = prevRootActive
		PopupManager.popPopup()
		if activeSession and activeSession.close == close then
			activeSession = nil
		end
		finishOnClose()
	end

	if not PopupManager.pushPopup({
		dim = true,
		blockInput = true,
		close = close,
		closeOthers = false,
		rootGui = rootGui,
	}) then
		contentGui.Active = prevContentActive
		rootGui.Active = prevRootActive
		finishOnClose()
		return
	end

	rootGui.Visible = true
	if not applyTitleRibbon(rootGui, normalizedTitleType) then
		close()
		return
	end
	if not applyRewards(rootGui, normalizedRewards) then
		close()
		return
	end

	if normalizedTitleType == "Purchase" then
		SoundManager.playSfx(SoundManager.Sfx.Buy)
	else
		SoundManager.playSfx(SoundManager.Sfx.RewardReveal)
	end

	prepareClickableButton(backgroundBtn)
	table.insert(connections, backgroundBtn.Activated:Connect(close))

	activeSession = { close = close }
end

function RewardPopup.close()
	if activeSession then
		activeSession.close()
	end
end

function RewardPopup.init()
	if initialized then
		return
	end
	initialized = true

	local rootGui = getRewardPopupRoot()
	if rootGui then
		local container = rootGui:FindFirstChild("Container")
		if container then
			ensureRewardTemplate(container)
			hideAllRewardSlots()
		end
	end

	print("[RewardPopup] 초기화 완료")
end

return RewardPopup
