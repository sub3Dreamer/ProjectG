--[[
	DailyRewardPopup (lobby client)

	GUI 트리: PopupScreenGui.Content.DailyRewardPopup (CanvasGroup)
		Container.LeftPanel — Day1 … Day6
		Container.Day7
		Top.CloseButton

	각 Day(CanvasGroup): Claimed, ClaimButton, ClaimEffect, RewardIcon, RewardCnt

	열기 시 서버 GetDailyRewardSnapshot → 보상·상태 갱신.
	RewardIcon: ReplicatedStorage.Client.Currency.{Gem,Gold,BattlePassPoint} 의 이미지 속성만 복사.
	ClaimButton: StringData[currencyType].kr 재화명 표기.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)
local StringHelper = require(Shared.Helpers.StringHelper)
local StringBinder = require(Shared.Helpers.StringBinder)
local LobbyNotificationBadge = require(script.Parent.Parent.LobbyNotificationBadge)

local BADGE_ID_DAILY_REWARD = "DailyReward"
local RewardPopup = require(script.Parent.RewardPopup)

local DailyRewardPopup = {}

local POPUP_ROOT_NAME = "DailyRewardPopup"
local GET_SNAPSHOT_REMOTE_NAME = "GetDailyRewardSnapshot"
local CLAIM_REMOTE_NAME = "ClaimDailyRewards"
local CURRENCY_FOLDER_PATH = { "Client", "Currency" }
local REWARD_DAYS = 7
local LOCALE = "kr"

local COLOR_CLAIMED = Color3.fromRGB(255, 255, 255)
local COLOR_CLAIMABLE = Color3.fromRGB(255, 238, 51)
local COLOR_LOCKED = Color3.fromRGB(255, 255, 255)

type DayState = "claimed" | "claimable" | "locked"

type RewardSnapshotEntry = {
	currencyType: string,
	amount: number,
}

type RewardSnapshot = {
	activeDatasetIndex: number,
	rewards: { RewardSnapshotEntry },
	currentDay: number?,
	claimedDays: { boolean }?,
	hasClaimable: boolean?,
}

type ClaimResult = {
	ok: boolean,
	claimedDays: { number }?,
	errorMessage: string?,
}

local initialized = false
local activeSession: { close: () -> () }? = nil
local snapshotRemote: RemoteFunction? = nil
local claimRemote: RemoteFunction? = nil
local currencyIcons: { [string]: ImageLabel? }? = nil
local claimingDay: number? = nil

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

local function findClaimButtonTextLabel(claimButton: GuiButton): TextLabel?
	for _, childName in { "TxtName", "Text", "Label" } do
		local child = claimButton:FindFirstChild(childName)
		if child and child:IsA("TextLabel") then
			return child :: TextLabel
		end
	end
	for _, descendant in claimButton:GetDescendants() do
		if descendant:IsA("TextLabel") then
			return descendant :: TextLabel
		end
	end
	return nil
end

local function applyClaimButtonLabel(claimButton: GuiButton, currencyType: string)
	local label = findClaimButtonTextLabel(claimButton)
	if not label then
		warn("[DailyRewardPopup] ClaimButton TextLabel 없음")
		return
	end
	label.Text = StringHelper.get(currencyType, LOCALE)
end

local function applyClaimButtonState(button: GuiButton, claimable: boolean)
	button.Active = claimable
	pcall(function()
		local btn = button :: any
		btn.Interactable = claimable
		btn.AutoButtonColor = claimable
		btn.Selectable = claimable
	end)
	if claimable and button:IsA("GuiObject") then
		local gui = button :: GuiObject
		gui.ZIndex = math.max(gui.ZIndex, 2)
	end
end

local function getDailyRewardPopupRoot(): GuiObject?
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
			warn("[DailyRewardPopup] ReplicatedStorage." .. table.concat(CURRENCY_FOLDER_PATH, ".") .. " 없음")
			return nil
		end
		folder = child
	end

	local icons: { [string]: ImageLabel? } = {}
	for _, currencyType in { "Gem", "Gold", "BattlePassPoint" } do
		local iconInst = folder:FindFirstChild(currencyType)
		local icon = if iconInst and iconInst:IsA("ImageLabel") then iconInst :: ImageLabel else nil
		if not icon then
			warn("[DailyRewardPopup] Client.Currency." .. currencyType .. " (ImageLabel) 없음")
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
	return "X" .. tostring(math.floor(amount))
end

local function findDayFrame(container: Instance, day: number): Instance?
	if day >= 1 and day <= 6 then
		local leftPanel = container:FindFirstChild("LeftPanel")
		if not leftPanel then
			return nil
		end
		return leftPanel:FindFirstChild("Day" .. tostring(day))
	end
	if day == 7 then
		return container:FindFirstChild("Day7")
	end
	return nil
end

local function getDayState(day: number, snapshot: RewardSnapshot): DayState
	local currentDay = snapshot.currentDay or 0
	local claimedDays = snapshot.claimedDays
	if claimedDays and claimedDays[day] then
		return "claimed"
	end
	if day <= currentDay then
		return "claimable"
	end
	return "locked"
end

local function applyDayState(dayFrame: Instance, state: DayState)
	local backgroundColor = if state == "claimable" then COLOR_CLAIMABLE else COLOR_LOCKED
	if state == "claimed" then
		backgroundColor = COLOR_CLAIMED
	end

	if dayFrame:IsA("CanvasGroup") then
		(dayFrame :: CanvasGroup).BackgroundColor3 = backgroundColor
	elseif dayFrame:IsA("Frame") then
		(dayFrame :: Frame).BackgroundColor3 = backgroundColor
	end

	local claimedInst = dayFrame:FindFirstChild("Claimed")
	if claimedInst and claimedInst:IsA("GuiObject") then
		(claimedInst :: GuiObject).Visible = state == "claimed"
	end

	local claimButtonInst = dayFrame:FindFirstChild("ClaimButton")
	if claimButtonInst and claimButtonInst:IsA("GuiButton") then
		applyClaimButtonState(claimButtonInst :: GuiButton, state == "claimable")
	end

	local claimEffectInst = dayFrame:FindFirstChild("ClaimEffect")
	if claimEffectInst and claimEffectInst:IsA("GuiObject") then
		(claimEffectInst :: GuiObject).Visible = state == "claimable"
	end
end

local function applyRewardToDayFrame(dayFrame: Instance, entry: RewardSnapshotEntry, icons: { [string]: ImageLabel? })
	local rewardIconInst = dayFrame:FindFirstChild("RewardIcon")
	local rewardCntInst = dayFrame:FindFirstChild("RewardCnt")
	if not (rewardIconInst and rewardIconInst:IsA("ImageLabel")) then
		warn("[DailyRewardPopup]", dayFrame.Name, "RewardIcon (ImageLabel) 없음")
		return
	end
	if not (rewardCntInst and rewardCntInst:IsA("TextLabel")) then
		warn("[DailyRewardPopup]", dayFrame.Name, "RewardCnt (TextLabel) 없음")
		return
	end

	local sourceIcon = icons[entry.currencyType]
	if not sourceIcon then
		warn("[DailyRewardPopup] currencyType 아이콘 없음:", entry.currencyType, dayFrame.Name)
		return
	end

	applyImageLabelImageProperties(sourceIcon, rewardIconInst :: ImageLabel)
	local rewardCnt = rewardCntInst :: TextLabel
	rewardCnt.Text = formatRewardCountText(entry.amount)

	local claimButtonInst = dayFrame:FindFirstChild("ClaimButton")
	if claimButtonInst and claimButtonInst:IsA("GuiButton") then
		applyClaimButtonLabel(claimButtonInst :: GuiButton, entry.currencyType)
	end
end

local function applySnapshotToPopup(rootGui: GuiObject, snapshot: RewardSnapshot)
	local icons = resolveCurrencyIcons()
	if not icons then
		return
	end

	local container = rootGui:FindFirstChild("Container")
	if not container then
		warn("[DailyRewardPopup] Container 없음")
		return
	end

	for day = 1, REWARD_DAYS do
		local entry = snapshot.rewards[day]
		if not entry then
			continue
		end
		local dayFrame = findDayFrame(container, day)
		if not dayFrame then
			warn("[DailyRewardPopup] Day", day, "프레임 없음")
			continue
		end
		applyRewardToDayFrame(dayFrame, entry, icons)
		applyDayState(dayFrame, getDayState(day, snapshot))
	end
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

local function fetchActiveSnapshot(): RewardSnapshot?
	local ok, result = pcall(function()
		return getSnapshotRemote():InvokeServer()
	end)
	if not ok then
		warn("[DailyRewardPopup] GetDailyRewardSnapshot 실패:", result)
		return nil
	end
	if typeof(result) ~= "table" or typeof(result.rewards) ~= "table" then
		warn("[DailyRewardPopup] GetDailyRewardSnapshot 응답 형식 오류")
		return nil
	end
	return result :: RewardSnapshot
end

local function showRewardPopupForClaim(day: number, snapshot: RewardSnapshot)
	local entry = snapshot.rewards[day]
	if not entry then
		return
	end
	task.defer(function()
		RewardPopup.open(RewardPopup.TitleType.Reward, entry.currencyType, entry.amount)
	end)
end

local function claimDayReward(day: number): ClaimResult?
	if claimingDay ~= nil then
		return nil
	end
	claimingDay = day

	local ok, result = pcall(function()
		return getClaimRemote():InvokeServer({ day })
	end)
	claimingDay = nil

	if not ok then
		warn("[DailyRewardPopup] ClaimDailyRewards 실패:", result)
		return nil
	end
	if typeof(result) ~= "table" then
		warn("[DailyRewardPopup] ClaimDailyRewards 응답 형식 오류")
		return nil
	end
	return result :: ClaimResult
end

local function bindClaimButtons(
	container: Instance,
	snapshotHolder: { current: RewardSnapshot? },
	rootGui: GuiObject,
	connections: { RBXScriptConnection }
)
	for day = 1, REWARD_DAYS do
		local dayFrame = findDayFrame(container, day)
		if not dayFrame then
			continue
		end
		local claimButtonInst = dayFrame:FindFirstChild("ClaimButton")
		if not (claimButtonInst and claimButtonInst:IsA("GuiButton")) then
			warn("[DailyRewardPopup]", dayFrame.Name, "ClaimButton 없음")
			continue
		end
		local claimBtn = claimButtonInst :: GuiButton

		table.insert(
			connections,
			claimBtn.Activated:Connect(function()
				local snapshot = snapshotHolder.current
				if not snapshot or getDayState(day, snapshot) ~= "claimable" then
					return
				end

				applyClaimButtonState(claimBtn, false)
				local claimResult = claimDayReward(day)
				if not claimResult or not claimResult.ok then
					snapshot = snapshotHolder.current
					if snapshot and getDayState(day, snapshot) == "claimable" then
						applyClaimButtonState(claimBtn, true)
					end
					if claimResult and claimResult.errorMessage then
						warn("[DailyRewardPopup] 수령 실패:", claimResult.errorMessage)
					end
					return
				end

				local refreshed = fetchActiveSnapshot()
				if refreshed then
					snapshotHolder.current = refreshed
					applySnapshotToPopup(rootGui, refreshed)
					LobbyNotificationBadge.setVisible(BADGE_ID_DAILY_REWARD, refreshed.hasClaimable == true)
				end

				showRewardPopupForClaim(day, snapshot)
			end)
		)
	end
end

function DailyRewardPopup.open()
	if activeSession then
		return
	end

	local rootGui = getDailyRewardPopupRoot()
	if not rootGui then
		warn("[DailyRewardPopup] Content.DailyRewardPopup 없음")
		return
	end
	StringBinder.applySubtreeOnce(rootGui)

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[DailyRewardPopup] Content 없음")
		return
	end

	local top = rootGui:FindFirstChild("Top")
	local closeInst = top and top:FindFirstChild("CloseButton")
	if not (closeInst and closeInst:IsA("GuiButton")) then
		warn("[DailyRewardPopup] Top.CloseButton 없음")
		return
	end
	local closeBtn = closeInst :: GuiButton

	local container = rootGui:FindFirstChild("Container")
	if not container then
		warn("[DailyRewardPopup] Container 없음")
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
	local snapshotHolder: { current: RewardSnapshot? } = { current = fetchActiveSnapshot() }

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

	if snapshotHolder.current then
		bindClaimButtons(container, snapshotHolder, rootGui, connections)
		applySnapshotToPopup(rootGui, snapshotHolder.current)
		LobbyNotificationBadge.setVisible(BADGE_ID_DAILY_REWARD, snapshotHolder.current.hasClaimable == true)
	end

	prepareClickableButton(closeBtn)
	table.insert(connections, closeBtn.Activated:Connect(close))

	activeSession = { close = close }
end

function DailyRewardPopup.close()
	if activeSession then
		activeSession.close()
	end
end

function DailyRewardPopup.init()
	if initialized then
		return
	end
	initialized = true
	print("[DailyRewardPopup] 초기화 완료")
end

return DailyRewardPopup
