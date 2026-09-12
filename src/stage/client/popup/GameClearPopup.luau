local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)
local SoundManager = require(Shared.Managers.SoundManager)
local Types = require(Shared.Types)
local StageEndState = require(script.Parent.Parent.StageEndState)

local GameClearPopup = {}

export type RewardEntry = {
	currencyType: Types.CurrencyType,
	amount: number,
	isBonus: boolean?, -- 버프로 인한 추가 보상 여부 (BonusRibbon 표시) — 버프 시스템 연동 전까지는 항상 nil/false
}

local FADE = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_QUICK = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local REWARDS_FRAME_NAME = "Rewards"
local REWARD_ITEM_NAME = "RewardItem"
local CURRENCY_FOLDER_PATH = { "Client", "Currency" }

local currencyIcons: { [Types.CurrencyType]: ImageLabel? }? = nil
local rewardItemTemplate: GuiObject? = nil
local rewardItemClones: { GuiObject } = {}

local function resolveCurrencyIcons(): { [Types.CurrencyType]: ImageLabel? }?
	if currencyIcons then
		return currencyIcons
	end

	local folder: Instance = ReplicatedStorage
	for _, name in CURRENCY_FOLDER_PATH do
		local child = folder:FindFirstChild(name)
		if not child then
			warn("[GameClearPopup] ReplicatedStorage." .. table.concat(CURRENCY_FOLDER_PATH, ".") .. " 없음")
			return nil
		end
		folder = child
	end

	local icons: { [Types.CurrencyType]: ImageLabel? } = {}
	for _, currencyType in Types.CURRENCY_TYPES do
		local iconInst = folder:FindFirstChild(currencyType)
		local icon = if iconInst and iconInst:IsA("ImageLabel") then iconInst :: ImageLabel else nil
		if not icon then
			warn("[GameClearPopup] Client.Currency." .. currencyType .. " (ImageLabel) 없음")
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

local function ensureRewardItemTemplate(rewardsFrame: GuiObject): boolean
	if rewardItemTemplate then
		return true
	end

	local templateInst = rewardsFrame:FindFirstChild(REWARD_ITEM_NAME)
	if not (templateInst and templateInst:IsA("GuiObject")) then
		warn("[GameClearPopup] Result.Rewards.RewardItem 없음")
		return false
	end

	local template = templateInst :: GuiObject
	template.Visible = false
	template.LayoutOrder = 0
	rewardItemTemplate = template
	return true
end

--- index=1은 원본 템플릿, 이후는 부족한 만큼만 Clone 생성 후 캐싱
local function getRewardItemSlot(index: number): GuiObject?
	local template = rewardItemTemplate
	if not template then
		return nil
	end

	if index == 1 then
		return template
	end

	local cloneIndex = index - 1
	while #rewardItemClones < cloneIndex do
		local clone = template:Clone()
		clone.Name = REWARD_ITEM_NAME .. tostring(#rewardItemClones + 2)
		clone.LayoutOrder = #rewardItemClones + 2
		clone.Parent = template.Parent
		table.insert(rewardItemClones, clone)
	end

	return rewardItemClones[cloneIndex]
end

local function hideAllRewardItemSlots()
	if rewardItemTemplate then
		rewardItemTemplate.Visible = false
	end
	for _, clone in rewardItemClones do
		clone.Visible = false
	end
end

local function applyRewardItemSlot(slot: GuiObject, entry: RewardEntry, icons: { [Types.CurrencyType]: ImageLabel? }): boolean
	local rewardIconInst = slot:FindFirstChild("RewardIcon")
	local rewardAmountInst = slot:FindFirstChild("RewardAmount")
	if not (rewardIconInst and rewardIconInst:IsA("ImageLabel")) then
		warn("[GameClearPopup]", slot.Name, "RewardIcon (ImageLabel) 없음")
		return false
	end
	if not (rewardAmountInst and rewardAmountInst:IsA("TextLabel")) then
		warn("[GameClearPopup]", slot.Name, "RewardAmount (TextLabel) 없음")
		return false
	end

	local sourceIcon = icons[entry.currencyType]
	if not sourceIcon then
		warn("[GameClearPopup] currencyType 아이콘 없음:", entry.currencyType)
		return false
	end

	applyImageLabelImageProperties(sourceIcon, rewardIconInst :: ImageLabel)
	local rewardAmountLabel = rewardAmountInst :: TextLabel
	rewardAmountLabel.Text = tostring(math.max(0, math.floor(entry.amount)))

	local bonusRibbonInst = slot:FindFirstChild("BonusRibbon")
	if bonusRibbonInst and bonusRibbonInst:IsA("GuiObject") then
		(bonusRibbonInst :: GuiObject).Visible = entry.isBonus == true
	end

	return true
end

local function applyRewards(resultGui: GuiObject, rewards: { RewardEntry })
	local icons = resolveCurrencyIcons()
	if not icons then
		return
	end

	local rewardsFrameInst = resultGui:FindFirstChild(REWARDS_FRAME_NAME)
	if not (rewardsFrameInst and rewardsFrameInst:IsA("GuiObject")) then
		warn("[GameClearPopup] Result.Rewards 없음")
		return
	end
	if not ensureRewardItemTemplate(rewardsFrameInst :: GuiObject) then
		return
	end

	hideAllRewardItemSlots()

	for index, entry in ipairs(rewards) do
		local slot = getRewardItemSlot(index)
		if not slot then
			warn("[GameClearPopup] RewardItem 슬롯 확보 실패:", index)
			break
		end
		slot.LayoutOrder = index
		slot.Visible = true
		applyRewardItemSlot(slot, entry, icons)
	end
end

local function formatTimeMmSs(totalSec: number): string
	local s = math.max(0, math.floor(totalSec + 0.5))
	local m = math.max(0, math.floor(s / 60))
	local r = s % 60
	return string.format("%d:%02d", m, r)
end

local function saveTextLabelState(l: TextLabel)
	return {
		TextTransparency = l.TextTransparency,
		TextStrokeTransparency = l.TextStrokeTransparency,
	}
end

local function applyTextLabelState(l: TextLabel, s: { TextTransparency: number, TextStrokeTransparency: number })
	l.TextTransparency = s.TextTransparency
	l.TextStrokeTransparency = s.TextStrokeTransparency
end

local function tweenTextLabelTo(l: TextLabel, t: number, s: number)
	local tw = TweenService:Create(
		l,
		FADE,
		{ TextTransparency = t, TextStrokeTransparency = s }
	)
	tw:Play()
	tw.Completed:Wait()
end

type ButtonSaved = { kind: string, Bg: number, Img: number?, Tx: number?, tText: number? }

local function saveButtonVisual(b: GuiButton): ButtonSaved
	if b:IsA("ImageButton") then
		local IB = b :: ImageButton
		local tText = 0
		for _, d in b:GetDescendants() do
			if d:IsA("TextLabel") then
				tText = (d :: TextLabel).TextTransparency
				break
			end
		end
		return {
			kind = "ImageButton",
			Bg = IB.BackgroundTransparency,
			Img = IB.ImageTransparency,
			tText = tText,
		}
	else
		local TB = b :: TextButton
		return {
			kind = "Text",
			Bg = TB.BackgroundTransparency,
			Tx = TB.TextTransparency,
		}
	end
end

local function setButtonFullyTransparent(b: GuiButton)
	if b:IsA("ImageButton") then
		local IB = b :: ImageButton
		IB.BackgroundTransparency = 1
		IB.ImageTransparency = 1
		for _, d in b:GetDescendants() do
			if d:IsA("TextLabel") then
				(d :: TextLabel).TextTransparency = 1
			end
		end
	else
		local TB = b :: TextButton
		TB.BackgroundTransparency = 1
		TB.TextTransparency = 1
	end
	b.Active = false
end

local function restoreButtonVisual(b: GuiButton, s: ButtonSaved)
	if s.kind == "ImageButton" then
		local IB = b :: ImageButton
		IB.BackgroundTransparency = s.Bg
		IB.ImageTransparency = s.Img or 0
		for _, d in b:GetDescendants() do
			if d:IsA("TextLabel") then
				(d :: TextLabel).TextTransparency = s.tText or 0
			end
		end
	else
		local TB = b :: TextButton
		TB.BackgroundTransparency = s.Bg
		TB.TextTransparency = s.Tx or 0
	end
end

--- Result 연출 뒤 Retry / Lobby 를 동시에 FadeIn
local function tweenTwoButtonsInParallel(b1: GuiButton, s1: ButtonSaved, b2: GuiButton, s2: ButtonSaved)
	setButtonFullyTransparent(b1)
	setButtonFullyTransparent(b2)

	local function playButtonFadeIn(b: GuiButton, s: ButtonSaved)
		if s.kind == "ImageButton" then
			local IB = b :: ImageButton
			local tw = TweenService:Create(
				IB,
				FADE,
				{ BackgroundTransparency = s.Bg, ImageTransparency = s.Img or 0 }
			)
			tw:Play()
			for _, d in b:GetDescendants() do
				if d:IsA("TextLabel") then
					local tl = d :: TextLabel
					TweenService:Create(tl, FADE_QUICK, {
						TextTransparency = s.tText or 0,
						TextStrokeTransparency = tl.TextStrokeTransparency,
					}):Play()
				end
			end
			return tw
		else
			local TB = b :: TextButton
			local tw = TweenService:Create(
				TB,
				FADE,
				{ BackgroundTransparency = s.Bg, TextTransparency = s.Tx or 0 }
			)
			tw:Play()
			return tw
		end
	end

	playButtonFadeIn(b1, s1)
	playButtonFadeIn(b2, s2)
	b1.Active = true
	b2.Active = true
end

--- `clearElapsedSec` = 제한시간 − 남은시간 (예: 300−40=260 → "4:20")
--- `rewards` = 스테이지 클리어 보상 목록 (StageHelper.getClearReward 결과, StageClearedEvent로 수신)
function GameClearPopup.start(clearElapsedSec: number, rewards: { RewardEntry }?)
	print("[GameClearPopup] start 진입, clearElapsedSec=", clearElapsedSec)
	-- 아래 연출(tween/task.wait)이 여러 프레임에 걸쳐 yield되는 동안, 보스 처치로 뒤늦게 도착한
	-- PetSavedEvent가 PetSavedPopup을 열어 이 팝업 위에 겹치지 않도록 가장 먼저 표시해둔다.
	StageEndState.markEnded()
	SoundManager.playSfx(SoundManager.Sfx.StageClear)
	local StageHUD = require(script.Parent.Parent.StageHUD) :: any

	if not PopupManager.getRootGui() then
		PopupManager.init()
	end
	local content = PopupManager.getContentFrame()
	if not content then
		warn("[GameClearPopup] Content 없음 (PopupManager.init, PopupScreenGui.Content 확인)")
		return
	end

	local root = content:FindFirstChild("GameClearPopup")
	if not (root and root:IsA("GuiObject")) then
		warn("[GameClearPopup] Content.GameClearPopup 을 찾을 수 없습니다")
		return
	end
	local rootGui = root :: GuiObject

	local result = root:FindFirstChild("Result")
	local title = result:FindFirstChild("Title")
	if not (title and title:IsA("TextLabel")) then
		warn("[GameClearPopup] Title (TextLabel) 없음")
		return
	end
	if not (result and result:IsA("GuiObject")) then
		warn("[GameClearPopup] Result 없음")
		return
	end
	local resultGui = result :: GuiObject

	local clearTimeTitle = result:FindFirstChild("ClearTimeTitle")
	local clearTimeText = result:FindFirstChild("ClearTimeText")
	if not (clearTimeText and clearTimeText:IsA("TextLabel")) then
		warn("[GameClearPopup] Result.ClearTimeText (TextLabel) 없음")
		return
	end

	local retryB = result:FindFirstChild("RetryButton")
	local lobbyB = result:FindFirstChild("LobbyButton")
	if not (retryB and retryB:IsA("GuiButton")) or not (lobbyB and lobbyB:IsA("GuiButton")) then
		warn("[GameClearPopup] GameClearPopup 하위 RetryButton / LobbyButton (GuiButton) 없음")
		return
	end
	local rBtn = retryB :: GuiButton
	local lBtn = lobbyB :: GuiButton

	local titleL = title :: TextLabel
	local cttL = clearTimeText :: TextLabel
	local ctitleL: TextLabel? = nil
	if clearTimeTitle and clearTimeTitle:IsA("TextLabel") then
		ctitleL = clearTimeTitle
	end

	local wasRootVis = rootGui.Visible
	local wasMsg = saveTextLabelState(titleL)
	local wasCtt = saveTextLabelState(cttL)
	local wasCttText = cttL.Text
	local wasCtitle: { TextTransparency: number, TextStrokeTransparency: number }? = ctitleL and saveTextLabelState(ctitleL)
		or nil
	local wasRetryB = saveButtonVisual(rBtn)
	local wasLobbyB = saveButtonVisual(lBtn)
	local wasRetryA = rBtn.Active
	local wasLobbyA = lBtn.Active
	local wasRetryVis = rBtn.Visible
	local wasLobbyVis = lBtn.Visible
	local wasResultVis = resultGui.Visible

	cttL.Text = formatTimeMmSs(clearElapsedSec)
	applyRewards(resultGui, rewards or {})

	local stageRetryEvent = ReplicatedStorage:WaitForChild("StageRetryRequestEvent") :: RemoteEvent
	local returnToLobbyEvent = ReplicatedStorage:WaitForChild("ReturnToLobbyRequestEvent") :: RemoteEvent

	local done = false
	local c1: RBXScriptConnection? = nil
	local c2: RBXScriptConnection? = nil

	local function finish()
		if done then
			return
		end
		done = true
		if c1 then
			c1:Disconnect()
		end
		if c2 then
			c2:Disconnect()
		end
		cttL.Text = wasCttText
		applyTextLabelState(titleL, wasMsg)
		applyTextLabelState(cttL, wasCtt)
		if ctitleL and wasCtitle then
			applyTextLabelState(ctitleL, wasCtitle)
		end
		restoreButtonVisual(rBtn, wasRetryB)
		restoreButtonVisual(lBtn, wasLobbyB)
		rBtn.Active = wasRetryA
		lBtn.Active = wasLobbyA
		rBtn.Visible = wasRetryVis
		lBtn.Visible = wasLobbyVis
		resultGui.Visible = wasResultVis
		rootGui.Visible = wasRootVis
		pcall(function()
			StageHUD.setGameplayInputLocked(false)
		end)
		PopupManager.popPopup()
	end

	print("[GameClearPopup] 인스턴스 검사 통과, pushPopup 직전")
	-- 스테이지 클리어 팝업이 뜰 때 PetSavedPopup 등 다른 stage 팝업이 같이 떠 있으면 안 되므로 강제로 닫는다.
	PopupManager.pushPopup({ close = finish, rootGui = rootGui, closeOthers = true })
	rootGui.Visible = true
	resultGui.Visible = true
	rBtn.Visible = false
	lBtn.Visible = false

	titleL.TextStrokeTransparency = wasMsg.TextStrokeTransparency
	titleL.TextTransparency = 1
	if ctitleL and wasCtitle then
		ctitleL.TextStrokeTransparency = wasCtitle.TextStrokeTransparency
		ctitleL.TextTransparency = 1
	end
	cttL.TextStrokeTransparency = wasCtt.TextStrokeTransparency
	cttL.TextTransparency = 1

	tweenTextLabelTo(
		titleL,
		wasMsg.TextTransparency,
		wasMsg.TextStrokeTransparency
	)
	task.wait(0.08)
	if ctitleL and wasCtitle then
		tweenTextLabelTo(ctitleL, wasCtitle.TextTransparency, wasCtitle.TextStrokeTransparency)
	end
	tweenTextLabelTo(cttL, wasCtt.TextTransparency, wasCtt.TextStrokeTransparency)

	task.wait(0.1)
	rBtn.Visible = true
	lBtn.Visible = true
	print("[GameClearPopup] tweenTwoButtonsInParallel 직전")
	tweenTwoButtonsInParallel(rBtn, wasRetryB, lBtn, wasLobbyB)
	print("[GameClearPopup] tween 끝. rBtn.Active=", rBtn.Active, "lBtn.Active=", lBtn.Active)

	c1 = rBtn.Activated:Connect(function()
		print("[GameClearPopup] retry clicked")
		stageRetryEvent:FireServer()
		finish()
	end)
	c2 = lBtn.Activated:Connect(function()
		print("[GameClearPopup] lobby clicked")
		returnToLobbyEvent:FireServer()
		finish()
	end)
end

return GameClearPopup
