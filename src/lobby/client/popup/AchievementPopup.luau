--[[
	AchievementPopup (lobby client)

	GUI 트리: PopupScreenGui.Content.AchievementPopup (CanvasGroup)
		Top.CloseButton
		ScrollingContainer — 업적 목록 (AchievementItem: Claimed, Notification)
		Info

	열기: LobbyScreenGui.LeftButtons.btnAchievement
	닫기: Top.CloseButton
	딤 없음 (dim = false)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)
local AchievementHelper = require(Shared.Helpers.AchievementHelper)
local StringHelper = require(Shared.Helpers.StringHelper)
local StringBinder = require(Shared.Helpers.StringBinder)
local RewardPopup = require(script.Parent.RewardPopup)
local LobbyNotificationBadge = require(script.Parent.Parent.LobbyNotificationBadge)
local AchievementClient = require(script.Parent.Parent.AchievementClient)

local AchievementPopup = {}

local POPUP_ROOT_NAME = "AchievementPopup"
local BADGE_ID_ACHIEVEMENT = "Achievement"
local GET_SNAPSHOT_REMOTE_NAME = "GetAchievementSnapshot"
local CLAIM_REMOTE_NAME = "ClaimAchievementReward"
local ACHIEVEMENT_ICON_FOLDER_PATH = { "Client", "Achievement" }
local CURRENCY_FOLDER_PATH = { "Client", "Currency" }
local LOCALE = "kr"

local initialized = false
local activeSession: { close: () -> () }? = nil
local cachedItems: { Frame } = {}
local cachedInfoRewards: { ImageLabel } = {}
local achievementIcons: { [string]: ImageLabel? }? = nil
local currencyIcons: { [string]: ImageLabel? }? = nil
local snapshotRemote: RemoteFunction? = nil
local claimRemote: RemoteFunction? = nil
local claimingAchievementIndex: number? = nil

type AchievementDefinition = AchievementHelper.AchievementDefinition
type AchievementButtonState = "in_progress" | "claimable" | "claimed"
type AchievementProgressMap = { [number]: number }
type AchievementClaimedMap = { [number]: boolean }

type AchievementSnapshot = {
	progress: AchievementProgressMap,
	claimed: AchievementClaimedMap,
	hasClaimable: boolean?,
}

type ClaimResult = {
	ok: boolean,
	errorMessage: string?,
	rewards: { { currencyType: string, amount: number } }?,
	snapshot: AchievementSnapshot?,
}

local function readSnapshotNumber(map: { [any]: any }, index: number): number?
	local value = map[index]
	if value == nil then
		value = map[tostring(index)]
	end
	if typeof(value) == "number" and value == value then
		return math.max(0, math.floor(value))
	end
	return nil
end

local function readSnapshotClaimed(map: { [any]: any }, index: number): boolean
	local value = map[index]
	if value == nil then
		value = map[tostring(index)]
	end
	return value == true or value == 1
end

local function normalizeAchievementSnapshot(raw: any): AchievementSnapshot?
	if typeof(raw) ~= "table" then
		return nil
	end

	local progressMap: AchievementProgressMap = {}
	local claimedMap: AchievementClaimedMap = {}
	local rawProgress = raw.progress
	local rawClaimed = raw.claimed

	if typeof(rawProgress) == "table" then
		for _, index in AchievementHelper.getAchievementIndices() do
			progressMap[index] = readSnapshotNumber(rawProgress, index) or 0
		end
	else
		return nil
	end

	if typeof(rawClaimed) == "table" then
		for _, index in AchievementHelper.getAchievementIndices() do
			claimedMap[index] = readSnapshotClaimed(rawClaimed, index)
		end
	else
		return nil
	end

	return {
		progress = progressMap,
		claimed = claimedMap,
		hasClaimable = if typeof(raw.hasClaimable) == "boolean" then raw.hasClaimable else nil,
	}
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

local function applyButtonState(button: GuiButton, enabled: boolean)
	button.Visible = enabled
	button.Active = enabled
	pcall(function()
		local btn = button :: any
		btn.Interactable = enabled
		btn.AutoButtonColor = enabled
		btn.Selectable = enabled
	end)
	if enabled and button:IsA("GuiObject") then
		local gui = button :: GuiObject
		gui.ZIndex = math.max(gui.ZIndex, 2)
	end
end

local function getAchievementPopupRoot(): GuiObject?
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

local function formatCountWithK(value: number): string
	local n = math.max(0, math.floor(value))
	if n < 1000 then
		return tostring(n)
	end

	local k = n / 1000
	if n % 1000 == 0 then
		return string.format("%dK", math.floor(k))
	end
	return string.format("%.1fK", k)
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

local function resolveAchievementIcons(): { [string]: ImageLabel? }?
	if achievementIcons then
		return achievementIcons
	end

	local folder: Instance = ReplicatedStorage
	for _, name in ACHIEVEMENT_ICON_FOLDER_PATH do
		local child = folder:FindFirstChild(name)
		if not child then
			warn("[AchievementPopup] ReplicatedStorage." .. table.concat(ACHIEVEMENT_ICON_FOLDER_PATH, ".") .. " 없음")
			return nil
		end
		folder = child
	end

	local icons: { [string]: ImageLabel? } = {}
	for _, index in AchievementHelper.getAchievementIndices() do
		local achievement = AchievementHelper.getAchievement(index)
		if achievement and icons[achievement.icon] == nil then
			local iconInst = folder:FindFirstChild(achievement.icon)
			local icon = if iconInst and iconInst:IsA("ImageLabel") then iconInst :: ImageLabel else nil
			if not icon then
				warn("[AchievementPopup] Client.Achievement." .. achievement.icon .. " (ImageLabel) 없음")
			end
			icons[achievement.icon] = icon
		end
	end

	achievementIcons = icons
	return achievementIcons
end

local function resolveCurrencyIcons(): { [string]: ImageLabel? }?
	if currencyIcons then
		return currencyIcons
	end

	local folder: Instance = ReplicatedStorage
	for _, name in CURRENCY_FOLDER_PATH do
		local child = folder:FindFirstChild(name)
		if not child then
			warn("[AchievementPopup] ReplicatedStorage." .. table.concat(CURRENCY_FOLDER_PATH, ".") .. " 없음")
			return nil
		end
		folder = child
	end

	local icons: { [string]: ImageLabel? } = {}
	for _, currencyType in { "Gem", "Gold", "BattlePassPoint" } do
		local iconInst = folder:FindFirstChild(currencyType)
		local icon = if iconInst and iconInst:IsA("ImageLabel") then iconInst :: ImageLabel else nil
		if not icon then
			warn("[AchievementPopup] Client.Currency." .. currencyType .. " (ImageLabel) 없음")
		end
		icons[currencyType] = icon
	end

	currencyIcons = icons
	return currencyIcons
end

local function findItemButton(item: Frame): GuiButton?
	if item:IsA("GuiButton") then
		return item
	end
	return nil
end

local function applyAchievementItemState(item: Frame, achievement: AchievementDefinition, snapshot: AchievementSnapshot)
	local goal = AchievementHelper.getProgressGoal(achievement)
	local currentRaw = readSnapshotNumber(snapshot.progress, achievement.index) or 0
	local current = math.clamp(math.max(0, math.floor(currentRaw)), 0, goal)
	local claimed = readSnapshotClaimed(snapshot.claimed, achievement.index)
	local claimable = not claimed and current >= goal

	local claimedInst = item:FindFirstChild("Claimed")
	if claimedInst and claimedInst:IsA("GuiObject") then
		(claimedInst :: GuiObject).Visible = claimed
	end

	local notificationInst = item:FindFirstChild("Notification")
	if notificationInst and notificationInst:IsA("GuiObject") then
		(notificationInst :: GuiObject).Visible = claimable
	end
end

local function refreshAchievementItemStates(rootGui: GuiObject, snapshot: AchievementSnapshot)
	local scrollingInst = rootGui:FindFirstChild("ScrollingContainer")
	if not scrollingInst then
		return
	end

	local order = 0
	for _, index in AchievementHelper.getAchievementIndices() do
		local achievement = AchievementHelper.getAchievement(index)
		if not achievement then
			continue
		end
		order += 1
		local item = cachedItems[order]
		if item and item.Parent == scrollingInst then
			applyAchievementItemState(item, achievement, snapshot)
		end
	end
end

local function resolveInfoButtonState(current: number, goal: number, claimed: boolean): AchievementButtonState
	if claimed then
		return "claimed"
	end
	if current >= goal then
		return "claimable"
	end
	return "in_progress"
end

local function applyInfoButtonState(info: Instance, state: AchievementButtonState)
	local btnProgressInst = info:FindFirstChild("BtnProgress")
	local btnRewardInst = info:FindFirstChild("BtnReward")
	local btnCompletedInst = info:FindFirstChild("BtnCompleted")

	if btnProgressInst and btnProgressInst:IsA("GuiButton") then
		applyButtonState(btnProgressInst :: GuiButton, state == "in_progress")
	else
		warn("[AchievementPopup] Info.BtnProgress (GuiButton) 없음")
	end
	if btnRewardInst and btnRewardInst:IsA("GuiButton") then
		applyButtonState(btnRewardInst :: GuiButton, state == "claimable")
	else
		warn("[AchievementPopup] Info.BtnReward (GuiButton) 없음")
	end
	if btnCompletedInst and btnCompletedInst:IsA("GuiButton") then
		applyButtonState(btnCompletedInst :: GuiButton, state == "claimed")
	else
		warn("[AchievementPopup] Info.BtnCompleted (GuiButton) 없음")
	end
end

local function applyInfoFill(info: Instance, current: number, goal: number)
	local xpBarInst = info:FindFirstChild("XPBar")
	if not xpBarInst then
		warn("[AchievementPopup] Info.XPBar 없음")
		return
	end

	local txtProgressCntInst = xpBarInst:FindFirstChild("TxtProgressCnt")
	if txtProgressCntInst and txtProgressCntInst:IsA("TextLabel") then
		txtProgressCntInst.Text = string.format("%d/%d", current, goal)
	else
		warn("[AchievementPopup] Info.XPBar.TxtProgressCnt (TextLabel) 없음")
	end

	local fillInst = xpBarInst:FindFirstChild("Fill")
	if not (fillInst and fillInst:IsA("GuiObject")) then
		warn("[AchievementPopup] Info.XPBar.Fill 없음")
		return
	end

	local fill = fillInst :: GuiObject
	local ratio = if goal > 0 then math.clamp(current / goal, 0, 1) else 0
	fill.Size = UDim2.new(ratio, 0, fill.Size.Y.Scale, fill.Size.Y.Offset)
end

local function getOrCreateInfoReward(container: Instance, template: ImageLabel, order: number): ImageLabel
	local reward = cachedInfoRewards[order]
	if not reward then
		if order == 1 then
			reward = template
		else
			reward = template:Clone()
			reward.Name = "Reward" .. tostring(order)
			reward.Parent = container
		end
		cachedInfoRewards[order] = reward
	end

	reward.Visible = true
	reward.LayoutOrder = order
	return reward
end

local function hideUnusedInfoRewards(startIndex: number)
	for i = startIndex, #cachedInfoRewards do
		local reward = cachedInfoRewards[i]
		if reward then
			reward.Visible = false
		end
	end
end

local function applyInfoRewards(info: Instance, achievement: AchievementDefinition, claimed: boolean)
	local rewardsInst = info:FindFirstChild("Rewards")
	if not rewardsInst then
		warn("[AchievementPopup] Info.Rewards 없음")
		return
	end

	local templateInst = rewardsInst:FindFirstChild("Reward")
	if not (templateInst and templateInst:IsA("ImageLabel")) then
		warn("[AchievementPopup] Info.Rewards.Reward (ImageLabel) 없음")
		return
	end

	local rewardsContainer = rewardsInst :: Instance
	local template = templateInst :: ImageLabel
	local icons = resolveCurrencyIcons()
	local order = 0

	for _, rewardEntry in achievement.rewards do
		order += 1
		local rewardFrame = getOrCreateInfoReward(rewardsContainer, template, order)

		if icons then
			local sourceIcon = icons[rewardEntry.currencyType]
			if sourceIcon then
				applyImageLabelImageProperties(sourceIcon, rewardFrame)
			end
		end

		local txtNameInst = rewardFrame:FindFirstChild("TxtName")
		if txtNameInst and txtNameInst:IsA("TextLabel") then
			txtNameInst.Text = StringHelper.get(rewardEntry.currencyType, LOCALE)
		else
			warn("[AchievementPopup] Info.Rewards.Reward.TxtName (TextLabel) 없음")
		end

		local txtCntInst = rewardFrame:FindFirstChild("TxtCnt")
		if txtCntInst and txtCntInst:IsA("TextLabel") then
			txtCntInst.Text = tostring(math.floor(rewardEntry.amount))
		else
			warn("[AchievementPopup] Info.Rewards.Reward.TxtCnt (TextLabel) 없음")
		end

		local claimedInst = rewardFrame:FindFirstChild("Claimed")
		if claimedInst and claimedInst:IsA("GuiObject") then
			claimedInst.Visible = claimed
		end
	end

	hideUnusedInfoRewards(order + 1)
end

local function getOrCreateItem(container: Instance, template: Frame, order: number): Frame
	local item = cachedItems[order]
	if not item then
		if order == 1 then
			item = template
		else
			item = template:Clone()
			item.Name = "AchievementItem" .. tostring(order)
			item.Parent = container
		end
		cachedItems[order] = item
	end

	item.Visible = true
	item.LayoutOrder = order
	return item
end

local function hideUnusedItems(startIndex: number)
	for i = startIndex, #cachedItems do
		local item = cachedItems[i]
		if item then
			item.Visible = false
		end
	end
end

local function applyMissionIcon(item: Frame, achievement: AchievementDefinition, icons: { [string]: ImageLabel? })
	local missionIconInst = item:FindFirstChild("MissionIcon")
	if not (missionIconInst and missionIconInst:IsA("ImageLabel")) then
		warn("[AchievementPopup]", item.Name, "MissionIcon (ImageLabel) 없음")
		return
	end

	local missionIcon = missionIconInst :: ImageLabel
	local sourceIcon = icons[achievement.icon]
	if sourceIcon then
		applyImageLabelImageProperties(sourceIcon, missionIcon)

		local sourceAspect = sourceIcon:FindFirstChildOfClass("UIAspectRatioConstraint")
		local targetAspect = missionIcon:FindFirstChildOfClass("UIAspectRatioConstraint")
		if sourceAspect and targetAspect then
			targetAspect.AspectRatio = sourceAspect.AspectRatio
			targetAspect.AspectType = sourceAspect.AspectType
			targetAspect.DominantAxis = sourceAspect.DominantAxis
		end
	end

	local missionCntInst = missionIcon:FindFirstChild("MissionCnt")
	if missionCntInst and missionCntInst:IsA("TextLabel") then
		missionCntInst.Text = formatCountWithK(achievement.progressCnt)
	else
		warn("[AchievementPopup]", item.Name, "MissionIcon.MissionCnt (TextLabel) 없음")
	end
end

local function focusAchievementInfo(rootGui: GuiObject, achievement: AchievementDefinition, snapshot: AchievementSnapshot)
	local infoInst = rootGui:FindFirstChild("Info")
	if not infoInst then
		warn("[AchievementPopup] Info 없음")
		return
	end
	local info = infoInst :: Instance

	local goal = AchievementHelper.getProgressGoal(achievement)
	local currentRaw = readSnapshotNumber(snapshot.progress, achievement.index) or 0
	local current = math.clamp(math.max(0, math.floor(currentRaw)), 0, goal)
	local claimed = readSnapshotClaimed(snapshot.claimed, achievement.index)

	local txtMissionTitleInst = info:FindFirstChild("TxtMissionTitle")
	if txtMissionTitleInst and txtMissionTitleInst:IsA("TextLabel") then
		txtMissionTitleInst.Text = AchievementHelper.formatTitle(achievement, LOCALE)
	else
		warn("[AchievementPopup] Info.TxtMissionTitle (TextLabel) 없음")
	end

	local state = resolveInfoButtonState(current, goal, claimed)
	applyInfoButtonState(info, state)
	applyInfoFill(info, current, goal)
	applyInfoRewards(info, achievement, claimed)
end

local function applySnapshotToUi(
	rootGui: GuiObject,
	snapshotHolder: { current: AchievementSnapshot? },
	focusedHolder: { current: number? },
	snapshot: AchievementSnapshot
)
	snapshotHolder.current = snapshot
	refreshAchievementItemStates(rootGui, snapshot)
	LobbyNotificationBadge.setVisible(BADGE_ID_ACHIEVEMENT, snapshot.hasClaimable == true)
	if focusedHolder.current then
		local focusedAchievement = AchievementHelper.getAchievement(focusedHolder.current)
		if focusedAchievement then
			focusAchievementInfo(rootGui, focusedAchievement, snapshot)
		end
	end
end

local function buildDefaultSnapshot(): AchievementSnapshot
	local progressMap: AchievementProgressMap = {}
	local claimedMap: AchievementClaimedMap = {}
	for _, index in AchievementHelper.getAchievementIndices() do
		progressMap[index] = 0
		claimedMap[index] = false
	end
	return {
		progress = progressMap,
		claimed = claimedMap,
		hasClaimable = false,
	}
end

local function getSnapshotRemote(): RemoteFunction
	local remote = snapshotRemote
	if not remote then
		remote = ReplicatedStorage:WaitForChild(GET_SNAPSHOT_REMOTE_NAME) :: RemoteFunction
		snapshotRemote = remote
	end
	return remote
end

local function getClaimRemote(): RemoteFunction
	local remote = claimRemote
	if not remote then
		remote = ReplicatedStorage:WaitForChild(CLAIM_REMOTE_NAME) :: RemoteFunction
		claimRemote = remote
	end
	return remote
end

local function fetchAchievementSnapshot(): AchievementSnapshot?
	local ok, result = pcall(function()
		return getSnapshotRemote():InvokeServer()
	end)
	if not ok then
		warn("[AchievementPopup] GetAchievementSnapshot 실패:", result)
		return nil
	end
	if typeof(result) ~= "table" or typeof(result.progress) ~= "table" or typeof(result.claimed) ~= "table" then
		warn("[AchievementPopup] GetAchievementSnapshot 응답 형식 오류")
		return nil
	end
	return normalizeAchievementSnapshot(result)
end

local function claimAchievementReward(achievementIndex: number): ClaimResult?
	if claimingAchievementIndex ~= nil then
		return nil
	end
	claimingAchievementIndex = achievementIndex

	local ok, result = pcall(function()
		return getClaimRemote():InvokeServer(achievementIndex)
	end)
	claimingAchievementIndex = nil

	if not ok then
		warn("[AchievementPopup] ClaimAchievementReward 실패:", result)
		return nil
	end
	if typeof(result) ~= "table" then
		warn("[AchievementPopup] ClaimAchievementReward 응답 형식 오류")
		return nil
	end

	local claimResult = result :: ClaimResult
	if typeof(claimResult.snapshot) == "table" then
		local normalizedSnapshot = normalizeAchievementSnapshot(claimResult.snapshot)
		if normalizedSnapshot then
			claimResult.snapshot = normalizedSnapshot
		else
			claimResult.snapshot = nil
		end
	end
	return claimResult
end

local function buildAchievementItems(
	rootGui: GuiObject,
	snapshotHolder: { current: AchievementSnapshot? },
	focusedHolder: { current: number? },
	connections: { RBXScriptConnection }
)
	local scrollingInst = rootGui:FindFirstChild("ScrollingContainer")
	if not scrollingInst then
		warn("[AchievementPopup] ScrollingContainer 없음")
		return
	end

	local templateInst = scrollingInst:FindFirstChild("AchievementItem")
	if not (templateInst and templateInst:IsA("ImageButton")) then
		warn("[AchievementPopup] ScrollingContainer.AchievementItem (ImageButton) 없음")
		return
	end

	local scrolling = scrollingInst :: Instance
	local template = templateInst :: Frame

	local icons = resolveAchievementIcons()
	if not icons then
		return
	end

	local order = 0
	for _, index in AchievementHelper.getAchievementIndices() do
		local achievement = AchievementHelper.getAchievement(index)
		if achievement then
			order += 1
			local item = getOrCreateItem(scrolling, template, order)
			applyMissionIcon(item, achievement, icons)
			local snapshot = snapshotHolder.current
			if snapshot then
				applyAchievementItemState(item, achievement, snapshot)
			end

			local button = findItemButton(item)
			if button then
				prepareClickableButton(button)
				table.insert(connections, button.Activated:Connect(function()
					local snapshot = snapshotHolder.current
					if not snapshot then
						return
					end
					focusedHolder.current = achievement.index
					focusAchievementInfo(rootGui, achievement, snapshot)
					applyAchievementItemState(item, achievement, snapshot)
				end))
			end
		end
	end

	hideUnusedItems(order + 1)

	local firstIndex = AchievementHelper.getAchievementIndices()[1]
	if firstIndex then
		local firstAchievement = AchievementHelper.getAchievement(firstIndex)
		local snapshot = snapshotHolder.current
		if firstAchievement and snapshot then
			focusedHolder.current = firstIndex
			focusAchievementInfo(rootGui, firstAchievement, snapshot)
		end
	end
end

local function bindInfoRewardButton(
	rootGui: GuiObject,
	snapshotHolder: { current: AchievementSnapshot? },
	focusedHolder: { current: number? },
	connections: { RBXScriptConnection }
)
	local infoInst = rootGui:FindFirstChild("Info")
	if not infoInst then
		return
	end
	local btnRewardInst = infoInst:FindFirstChild("BtnReward")
	if not (btnRewardInst and btnRewardInst:IsA("GuiButton")) then
		warn("[AchievementPopup] Info.BtnReward (GuiButton) 없음")
		return
	end
	local btnReward = btnRewardInst :: GuiButton
	prepareClickableButton(btnReward)
	table.insert(
		connections,
		btnReward.Activated:Connect(function()
			local snapshot = snapshotHolder.current
			local focusedIndex = focusedHolder.current
			if not snapshot or focusedIndex == nil then
				return
			end
			if readSnapshotClaimed(snapshot.claimed, focusedIndex) then
				return
			end
			local achievement = AchievementHelper.getAchievement(focusedIndex)
			if not achievement then
				return
			end
			local current = readSnapshotNumber(snapshot.progress, focusedIndex) or 0
			if current < AchievementHelper.getProgressGoal(achievement) then
				return
			end

			local claimResult = claimAchievementReward(focusedIndex)
			if not claimResult or not claimResult.ok then
				return
			end

			local refreshed = claimResult.snapshot or fetchAchievementSnapshot()
			if refreshed then
				applySnapshotToUi(rootGui, snapshotHolder, focusedHolder, refreshed)
			end

			local rewards = claimResult.rewards
			if rewards and #rewards > 0 then
				task.defer(function()
					RewardPopup.open(RewardPopup.TitleType.Reward, rewards)
				end)
			end
		end)
	)
end

function AchievementPopup.open(skipEntranceAnimation: boolean?)
	if activeSession then
		return
	end

	local rootGui = getAchievementPopupRoot()
	if not rootGui then
		warn("[AchievementPopup] Content.AchievementPopup 없음")
		return
	end
	StringBinder.applySubtreeOnce(rootGui)

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[AchievementPopup] Content 없음")
		return
	end

	local top = rootGui:FindFirstChild("Top")
	local closeInst = top and top:FindFirstChild("CloseButton")
	if not (closeInst and closeInst:IsA("GuiButton")) then
		warn("[AchievementPopup] Top.CloseButton 없음")
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
	local snapshotHolder: { current: AchievementSnapshot? } = {
		current = fetchAchievementSnapshot() or buildDefaultSnapshot(),
	}
	local focusedHolder: { current: number? } = { current = nil }

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
	buildAchievementItems(rootGui, snapshotHolder, focusedHolder, connections)
	bindInfoRewardButton(rootGui, snapshotHolder, focusedHolder, connections)
	AchievementClient.refreshNotification()

	prepareClickableButton(closeBtn)
	table.insert(connections, closeBtn.Activated:Connect(close))

	activeSession = { close = close }
end

function AchievementPopup.close()
	if activeSession then
		activeSession.close()
	end
end

function AchievementPopup.init()
	if initialized then
		return
	end
	initialized = true
	print("[AchievementPopup] 초기화 완료")
end

return AchievementPopup
