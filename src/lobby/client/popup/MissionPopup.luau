--[[
	MissionPopup (lobby client)

	GUI 트리: PopupScreenGui.Content.MissionPopup (CanvasGroup)
		Top.CloseButton
		TxtRemainTime — 일일 미션 갱신까지 남은 시간
		ScrollingContainer — Mission1, Mission2, Mission3
			TxtMissionTitle
			BtnProgress, BtnReward, BtnCompleted
			XPBar.Fill, XPBar.TxtProgressCnt
			Reward1, Reward2 — TxtCnt, TxtName

	열기: LobbyScreenGui.LeftButtons.btnQuest
	닫기: Top.CloseButton
	딤 없음 (dim = false)

	RewardIcon: ReplicatedStorage.Client.Currency.{Gem,Gold,BattlePassPoint} 의 이미지 속성만 복사.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local PopupManager = require(Shared.Managers.PopupManager)
local MissionHelper = require(Shared.Helpers.MissionHelper)
local StringHelper = require(Shared.Helpers.StringHelper)
local StringBinder = require(Shared.Helpers.StringBinder)
local RewardPopup = require(script.Parent.RewardPopup)
local LobbyNotificationBadge = require(script.Parent.Parent.LobbyNotificationBadge)
local MissionClient = require(script.Parent.Parent.MissionClient)

local MissionPopup = {}

type MissionDefinition = Types.MissionDefinition
type MissionRewardEntry = Types.MissionRewardEntry
type MissionProgressMap = { [number]: number }
type MissionClaimedMap = { [number]: boolean }
type MissionButtonState = "in_progress" | "claimable" | "claimed"

type MissionSnapshot = {
	selectedIndices: { number },
	progress: MissionProgressMap,
	claimed: MissionClaimedMap,
	hasClaimable: boolean?,
}

type ClaimResult = {
	ok: boolean,
	errorMessage: string?,
	rewards: { MissionRewardEntry }?,
}

local POPUP_ROOT_NAME = "MissionPopup"
local BADGE_ID_MISSION = "Mission"
local GET_SNAPSHOT_REMOTE_NAME = "GetMissionSnapshot"
local CLAIM_REMOTE_NAME = "ClaimMissionReward"
local LOCALE = "kr"
local REMAIN_TIME_UPDATE_INTERVAL = 0.1
local CURRENCY_FOLDER_PATH = { "Client", "Currency" }

local initialized = false
local activeSession: { close: () -> () }? = nil
local currencyIcons: { [string]: ImageLabel? }? = nil
local snapshotRemote: RemoteFunction? = nil
local claimRemote: RemoteFunction? = nil
local claimingMissionIndex: number? = nil

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

local function getMissionPopupRoot(): GuiObject?
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
			warn("[MissionPopup] ReplicatedStorage." .. table.concat(CURRENCY_FOLDER_PATH, ".") .. " 없음")
			return nil
		end
		folder = child
	end

	local icons: { [string]: ImageLabel? } = {}
	for _, currencyType in { "Gem", "Gold", "BattlePassPoint" } do
		local iconInst = folder:FindFirstChild(currencyType)
		local icon = if iconInst and iconInst:IsA("ImageLabel") then iconInst :: ImageLabel else nil
		if not icon then
			warn("[MissionPopup] Client.Currency." .. currencyType .. " (ImageLabel) 없음")
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

local function findTxtRemainTime(rootGui: GuiObject): TextLabel?
	local txtInst = rootGui:FindFirstChild("TxtRemainTime")
	if txtInst and txtInst:IsA("TextLabel") then
		return txtInst :: TextLabel
	end
	return nil
end

local function findMissionFrame(scrollingContainer: Instance, index: number): Instance?
	return scrollingContainer:FindFirstChild("Mission" .. tostring(index))
end

local function applyRewardSlot(
	rewardFrame: ImageLabel,
	entry: MissionRewardEntry,
	locale: string,
	icons: { [string]: ImageLabel? }
)
	local sourceIcon = icons[entry.currencyType]
	if sourceIcon then
		applyImageLabelImageProperties(sourceIcon, rewardFrame)
	end

	local txtCntInst = rewardFrame:FindFirstChild("TxtCnt")
	if txtCntInst and txtCntInst:IsA("TextLabel") then
		local txtCnt = txtCntInst :: TextLabel
		txtCnt.Text = tostring(math.floor(entry.amount))
	end

	local txtNameInst = rewardFrame:FindFirstChild("TxtName")
	if txtNameInst and txtNameInst:IsA("TextLabel") then
		local txtName = txtNameInst :: TextLabel
		txtName.Text = StringHelper.get(entry.currencyType, locale)
	end
end

local function applyMissionButtonState(missionFrame: Instance, buttonState: MissionButtonState)
	local btnProgressInst = missionFrame:FindFirstChild("BtnProgress")
	local btnRewardInst = missionFrame:FindFirstChild("BtnReward")
	local btnCompletedInst = missionFrame:FindFirstChild("BtnCompleted")
	if not (btnProgressInst and btnProgressInst:IsA("GuiButton")) then
		warn("[MissionPopup]", missionFrame.Name, "BtnProgress (GuiButton) 없음")
		return
	end
	if not (btnRewardInst and btnRewardInst:IsA("GuiButton")) then
		warn("[MissionPopup]", missionFrame.Name, "BtnReward (GuiButton) 없음")
		return
	end
	if not (btnCompletedInst and btnCompletedInst:IsA("GuiButton")) then
		warn("[MissionPopup]", missionFrame.Name, "BtnCompleted (GuiButton) 없음")
		return
	end

	applyButtonState(btnProgressInst :: GuiButton, buttonState == "in_progress")
	applyButtonState(btnRewardInst :: GuiButton, buttonState == "claimable")
	applyButtonState(btnCompletedInst :: GuiButton, buttonState == "claimed")
end

local function resolveMissionButtonState(current: number, goal: number, claimed: boolean): MissionButtonState
	if claimed then
		return "claimed"
	end
	if current >= goal then
		return "claimable"
	end
	return "in_progress"
end

local function applyProgressBar(missionFrame: Instance, current: number, goal: number)
	local xpBar = missionFrame:FindFirstChild("XPBar")
	if not xpBar then
		warn("[MissionPopup]", missionFrame.Name, "XPBar 없음")
		return
	end

	local progressCntInst = xpBar:FindFirstChild("TxtProgressCnt")
	if progressCntInst and progressCntInst:IsA("TextLabel") then
		local progressLabel = progressCntInst :: TextLabel
		progressLabel.Text = string.format("%d/%d", current, goal)
	else
		warn("[MissionPopup]", missionFrame.Name, "XPBar.TxtProgressCnt (TextLabel) 없음")
	end

	local fillInst = xpBar:FindFirstChild("Fill")
	if not (fillInst and fillInst:IsA("GuiObject")) then
		warn("[MissionPopup]", missionFrame.Name, "XPBar.Fill 없음")
		return
	end

	local fill = fillInst :: GuiObject
	local ratio = if goal > 0 then math.clamp(current / goal, 0, 1) else 0
	fill.Size = UDim2.new(ratio, 0, fill.Size.Y.Scale, fill.Size.Y.Offset)
end

local function applyMissionRow(
	missionFrame: Instance,
	mission: MissionDefinition,
	currentProgress: number,
	claimed: boolean,
	locale: string,
	icons: { [string]: ImageLabel? }
)
	local goal = mission.progressCnt
	local current = math.clamp(math.floor(currentProgress), 0, goal)
	local buttonState = resolveMissionButtonState(current, goal, claimed)

	local titleInst = missionFrame:FindFirstChild("TxtMissionTitle")
	if titleInst and titleInst:IsA("TextLabel") then
		local template = StringHelper.get(mission.stringKey, locale)
		local titleLabel = titleInst :: TextLabel
		titleLabel.Text = StringHelper.format(template, goal)
	else
		warn("[MissionPopup]", missionFrame.Name, "TxtMissionTitle (TextLabel) 없음")
	end

	applyMissionButtonState(missionFrame, buttonState)
	applyProgressBar(missionFrame, current, goal)

	for slot = 1, 2 do
		local rewardInst = missionFrame:FindFirstChild("Reward" .. tostring(slot))
		local entry = mission.rewards[slot]
		if rewardInst and rewardInst:IsA("ImageLabel") then
			local rewardFrame = rewardInst :: ImageLabel
			if entry then
				rewardFrame.Visible = true
				applyRewardSlot(rewardFrame, entry, locale, icons)
			else
				rewardFrame.Visible = false
			end
		elseif entry then
			warn("[MissionPopup]", missionFrame.Name, "Reward" .. tostring(slot), "(ImageLabel) 없음")
		end
	end
end

local function buildDefaultSnapshot(): MissionSnapshot
	return {
		selectedIndices = {},
		progress = {},
		claimed = {},
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

local function fetchMissionSnapshot(): MissionSnapshot?
	local ok, result = pcall(function()
		return getSnapshotRemote():InvokeServer()
	end)
	if not ok then
		warn("[MissionPopup] GetMissionSnapshot 실패:", result)
		return nil
	end
	if typeof(result) ~= "table" or typeof(result.progress) ~= "table" or typeof(result.claimed) ~= "table" then
		warn("[MissionPopup] GetMissionSnapshot 응답 형식 오류")
		return nil
	end
	return result :: MissionSnapshot
end

local function claimMissionReward(missionIndex: number): ClaimResult?
	if claimingMissionIndex ~= nil then
		return nil
	end
	claimingMissionIndex = missionIndex

	local ok, result = pcall(function()
		return getClaimRemote():InvokeServer(missionIndex)
	end)
	claimingMissionIndex = nil

	if not ok then
		warn("[MissionPopup] ClaimMissionReward 실패:", result)
		return nil
	end
	if typeof(result) ~= "table" then
		warn("[MissionPopup] ClaimMissionReward 응답 형식 오류")
		return nil
	end
	return result :: ClaimResult
end

local function applyMissionsToPopup(rootGui: GuiObject, snapshot: MissionSnapshot)
	local icons = resolveCurrencyIcons()
	if not icons then
		return
	end

	local scrolling = rootGui:FindFirstChild("ScrollingContainer")
	if not scrolling then
		warn("[MissionPopup] ScrollingContainer 없음")
		return
	end

	for slot, index in ipairs(snapshot.selectedIndices) do
		local mission = MissionHelper.getMission(index)
		local missionFrame = findMissionFrame(scrolling, slot)
		if not mission then
			continue
		end
		if not missionFrame then
			warn("[MissionPopup] Mission", slot, "프레임 없음")
			continue
		end
		local current = snapshot.progress[index] or 0
		local claimed = snapshot.claimed[index] == true
		applyMissionRow(missionFrame, mission, current, claimed, LOCALE, icons)
	end
end

local function bindRewardButtons(
	rootGui: GuiObject,
	snapshotHolder: { current: MissionSnapshot? },
	connections: { RBXScriptConnection }
)
	local scrolling = rootGui:FindFirstChild("ScrollingContainer")
	if not scrolling then
		return
	end

	local selectedIndices = if snapshotHolder.current then snapshotHolder.current.selectedIndices else {}
	for slot, index in ipairs(selectedIndices) do
		local missionFrame = findMissionFrame(scrolling, slot)
		if not missionFrame then
			continue
		end
		local btnRewardInst = missionFrame:FindFirstChild("BtnReward")
		if not (btnRewardInst and btnRewardInst:IsA("GuiButton")) then
			continue
		end
		local btnReward = btnRewardInst :: GuiButton
		prepareClickableButton(btnReward)
		table.insert(
			connections,
			btnReward.Activated:Connect(function()
				local snapshot = snapshotHolder.current
				if not snapshot then
					return
				end
				if snapshot.claimed[index] == true then
					return
				end
				local mission = MissionHelper.getMission(index)
				if not mission then
					return
				end
				local current = snapshot.progress[index] or 0
				if current < mission.progressCnt then
					return
				end

				local claimResult = claimMissionReward(index)
				if not claimResult or not claimResult.ok then
					return
				end

				local refreshed = fetchMissionSnapshot()
				if refreshed then
					snapshotHolder.current = refreshed
					applyMissionsToPopup(rootGui, refreshed)
					LobbyNotificationBadge.setVisible(BADGE_ID_MISSION, refreshed.hasClaimable == true)
				end

				local rewards = claimResult.rewards
				if rewards and #rewards > 0 then
					local rewardEntries = {}
					for _, reward in rewards do
						table.insert(rewardEntries, {
							currencyType = reward.currencyType,
							amount = reward.amount,
						})
					end
					task.defer(function()
						RewardPopup.open(RewardPopup.TitleType.Reward, rewardEntries)
					end)
				end
			end)
		)
	end
end

local function startRemainTimeUpdater(
	rootGui: GuiObject,
	connections: { RBXScriptConnection },
	isClosed: () -> boolean
)
	local txtRemainTime = findTxtRemainTime(rootGui)
	if not txtRemainTime then
		warn("[MissionPopup] TxtRemainTime 없음")
		return
	end

	local function updateRemainTime()
		local remainingSec = MissionHelper.getSecondsUntilDailyReset()
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

function MissionPopup.open(skipEntranceAnimation: boolean?)
	if activeSession then
		return
	end

	local rootGui = getMissionPopupRoot()
	if not rootGui then
		warn("[MissionPopup] Content.MissionPopup 없음")
		return
	end
	StringBinder.applySubtreeOnce(rootGui)

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[MissionPopup] Content 없음")
		return
	end

	local top = rootGui:FindFirstChild("Top")
	local closeInst = top and top:FindFirstChild("CloseButton")
	if not (closeInst and closeInst:IsA("GuiButton")) then
		warn("[MissionPopup] Top.CloseButton 없음")
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
	local snapshotHolder: { current: MissionSnapshot? } = { current = fetchMissionSnapshot() or buildDefaultSnapshot() }

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

	applyMissionsToPopup(rootGui, snapshotHolder.current :: MissionSnapshot)
	bindRewardButtons(rootGui, snapshotHolder, connections)
	MissionClient.refreshNotification()

	prepareClickableButton(closeBtn)
	table.insert(connections, closeBtn.Activated:Connect(close))
	startRemainTimeUpdater(rootGui, connections, function()
		return closed
	end)

	activeSession = { close = close }
end

function MissionPopup.close()
	if activeSession then
		activeSession.close()
	end
end

function MissionPopup.init()
	if initialized then
		return
	end
	initialized = true
	print("[MissionPopup] 초기화 완료")
end

return MissionPopup
