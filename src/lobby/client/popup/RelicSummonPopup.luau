--[[
	RelicSummonPopup (lobby client)

	GUI 트리: PopupScreenGui.Content.RelicSummonPopup (CanvasGroup)
		Container.Chest — Chest_Close, Chest_Open
		Container.RelicInfo — Text.Grade, Text.Name, Slot.RelicIcon
		Container.RelicList.Layout — RelicSlot ×10 (미리 배치)
		BackgroundButton, TxtDesc, BtnSkip

	열기: RelicSummonPopup.play(results, onFinished?)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)
local SoundManager = require(Shared.Managers.SoundManager)
local StringHelper = require(Shared.Helpers.StringHelper)
local StringBinder = require(Shared.Helpers.StringBinder)
local RelicHelper = require(Shared.Helpers.RelicHelper)

local RelicSummonPopup = {}

local POPUP_ROOT_NAME = "RelicSummonPopup"

local CHEST_SHAKE_STEP = 0.05
local CHEST_SHAKE_CYCLES = 4
local CHEST_SHAKE_DEGREES = 5
local RELIC_INFO_RISE_DURATION = 0.4
local RELIC_INFO_START_Y = 0.75
local RELIC_INFO_END_Y = 0.25
local RELIC_LIST_STAMP_INTERVAL = 0.08

local LOCALE = "kr"

local function getTapNextText(): string
	return StringHelper.get("RelicSummon_TapNext", LOCALE)
end

local function getTapCloseText(): string
	return StringHelper.get("RelicSummon_TapClose", LOCALE)
end

local function getGradeLabel(grade: string): string
	local key = "RelicGrade_" .. grade
	local text = StringHelper.get(key, LOCALE)
	if text == key then
		return grade
	end
	return text
end

export type SummonRelicResult = {
	id: number,
	name: string,
	grade: string,
}

type ActiveSession = {
	token: number,
	skipped: boolean,
	inSummary: boolean,
	waitingTap: boolean,
	resumeTap: (() -> ())?,
	cancelShake: (() -> ())?,
	close: () -> (),
}

local initialized = false
local sessionToken = 0
local activeSession: ActiveSession? = nil

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

local function getRelicSummonPopupRoot(): GuiObject?
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

local function bindRelicToSlotRoot(slotRoot: Instance, result: SummonRelicResult)
	local slotContainer = slotRoot:FindFirstChild("Slot")
	if slotContainer then
		RelicHelper.applyGradeSlotBg(slotContainer, result.grade)
	end

	local relicIconInst = RelicHelper.findRelicIconImageLabel(slotRoot)
	if relicIconInst then
		RelicHelper.applyRelicIconToImageLabel(relicIconInst, result.id)
	end
end

type UiRefs = {
	rootGui: GuiObject,
	container: Instance?,
	chest: GuiObject?,
	chestClose: GuiObject?,
	chestOpen: GuiObject?,
	relicInfo: GuiObject?,
	relicList: GuiObject?,
	layout: Instance?,
	txtDesc: TextLabel?,
	btnSkip: GuiButton?,
	backgroundBtn: GuiButton?,
}

local function getDescendantDepth(rootGui: GuiObject, inst: Instance): number
	local depth = 0
	local current: Instance? = inst
	while current and current ~= rootGui do
		depth += 1
		current = current.Parent
	end
	return depth
end

local function resolveTxtDesc(rootGui: GuiObject): TextLabel?
	local best: TextLabel? = nil
	local bestDepth = math.huge

	for _, inst in rootGui:GetDescendants() do
		if inst.Name == "TxtDesc" and inst:IsA("TextLabel") then
			local depth = getDescendantDepth(rootGui, inst)
			if depth < bestDepth then
				bestDepth = depth
				best = inst
			end
		end
	end

	return best
end

local function bindTxtDesc(rootGui: GuiObject, refs: UiRefs): TextLabel?
	local label = resolveTxtDesc(rootGui)
	if not label then
		local direct = rootGui:FindFirstChild("TxtDesc")
		if direct and direct:IsA("TextLabel") then
			label = direct
		end
	end
	refs.txtDesc = label
	return label
end

local function setTxtDesc(refs: UiRefs, text: string)
	local label = refs.txtDesc
	if not label or not label:IsDescendantOf(refs.rootGui) then
		label = bindTxtDesc(refs.rootGui, refs)
	end
	if not label then
		return
	end

	label.Text = text
	label.TextTransparency = 0
	label.TextStrokeTransparency = 0
	label.Visible = true
end

local function getUiRefs(rootGui: GuiObject): UiRefs
	local container = rootGui:FindFirstChild("Container")
	local chest = container and container:FindFirstChild("Chest")
	local chestClose = chest and chest:FindFirstChild("Chest_Close")
	local chestOpen = chest and chest:FindFirstChild("Chest_Open")
	local relicInfo = container and container:FindFirstChild("RelicInfo")
	local relicList = container and container:FindFirstChild("RelicList")
	local layout = relicList and relicList:FindFirstChild("Layout")
	local btnSkip = rootGui:FindFirstChild("BtnSkip")
	if not btnSkip then
		btnSkip = rootGui:FindFirstChild("BtnSkip", true)
	end
	local backgroundBtn = rootGui:FindFirstChild("BackgroundButton")

	local refs: UiRefs = {
		rootGui = rootGui,
		container = container,
		chest = if chest and chest:IsA("GuiObject") then chest :: GuiObject else nil,
		chestClose = if chestClose and chestClose:IsA("GuiObject") then chestClose :: GuiObject else nil,
		chestOpen = if chestOpen and chestOpen:IsA("GuiObject") then chestOpen :: GuiObject else nil,
		relicInfo = if relicInfo and relicInfo:IsA("GuiObject") then relicInfo :: GuiObject else nil,
		relicList = if relicList and relicList:IsA("GuiObject") then relicList :: GuiObject else nil,
		layout = layout,
		txtDesc = nil,
		btnSkip = if btnSkip and btnSkip:IsA("GuiButton") then btnSkip :: GuiButton else nil,
		backgroundBtn = if backgroundBtn and backgroundBtn:IsA("GuiButton") then backgroundBtn :: GuiButton else nil,
	}
	bindTxtDesc(rootGui, refs)
	return refs
end

local function collectRelicSlots(layout: Instance?): { GuiObject }
	local slots: { GuiObject } = {}
	if not layout then
		return slots
	end
	for _, child in layout:GetChildren() do
		if child:IsA("GuiObject") and child.Name == "RelicSlot" then
			table.insert(slots, child :: GuiObject)
		end
	end
	table.sort(slots, function(a, b)
		if a.LayoutOrder ~= b.LayoutOrder then
			return a.LayoutOrder < b.LayoutOrder
		end
		return a.Name < b.Name
	end)
	return slots
end

local function setVisible(gui: GuiObject?, visible: boolean)
	if gui then
		gui.Visible = visible
	end
end

local function resetChest(refs: any)
	if refs.chestClose then
		refs.chestClose.Visible = true
		refs.chestClose.Rotation = 0
	end
	if refs.chestOpen then
		refs.chestOpen.Visible = false
	end
	if refs.chest then
		setVisible(refs.chest, true)
	end
end

local function resetRelicListSlots(slots: { GuiObject })
	for _, slot in slots do
		slot.Visible = false
	end
end

local function playChestShake(session: ActiveSession, chestClose: GuiObject): ()
	local startRot = chestClose.Rotation
	local cancelled = false
	session.cancelShake = function()
		cancelled = true
		chestClose.Rotation = startRot
	end

	SoundManager.playSfx(SoundManager.Sfx.Rewards)

	for _ = 1, CHEST_SHAKE_CYCLES do
		if cancelled or session.skipped or session.token ~= sessionToken then
			break
		end
		local tw1 = TweenService:Create(
			chestClose,
			TweenInfo.new(CHEST_SHAKE_STEP, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
			{ Rotation = startRot + CHEST_SHAKE_DEGREES }
		)
		tw1:Play()
		tw1.Completed:Wait()
		if cancelled or session.skipped then
			break
		end
		local tw2 = TweenService:Create(
			chestClose,
			TweenInfo.new(CHEST_SHAKE_STEP, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
			{ Rotation = startRot - CHEST_SHAKE_DEGREES }
		)
		tw2:Play()
		tw2.Completed:Wait()
	end

	chestClose.Rotation = startRot
	session.cancelShake = nil
end

local function openChest(refs: any)
	if refs.chestClose then
		refs.chestClose.Visible = false
		refs.chestClose.Rotation = 0
	end
	if refs.chestOpen then
		refs.chestOpen.Visible = true
	end
end

local function bindRelicInfo(relicInfo: GuiObject, result: SummonRelicResult)
	local textFrame = relicInfo:FindFirstChild("Text")
	local gradeInst = textFrame and textFrame:FindFirstChild("Grade")
	local nameInst = textFrame and textFrame:FindFirstChild("Name")
	if gradeInst and gradeInst:IsA("TextLabel") then
		(gradeInst :: TextLabel).Text = getGradeLabel(result.grade)
	end
	if nameInst and nameInst:IsA("TextLabel") then
		(nameInst :: TextLabel).Text = StringHelper.get(result.name, LOCALE)
	end

	local slotContainer = relicInfo:FindFirstChild("Slot")
	if slotContainer then
		RelicHelper.applyGradeSlotBg(slotContainer, result.grade)
	end

	local relicIconInst = RelicHelper.findRelicIconImageLabel(relicInfo)
	if relicIconInst then
		RelicHelper.applyRelicIconToImageLabel(relicIconInst, result.id)
	end
end

local function prepareRelicInfoHidden(relicInfo: GuiObject, hideTextDuringRise: boolean)
	local textFrame = relicInfo:FindFirstChild("Text")
	if textFrame and textFrame:IsA("GuiObject") then
		(textFrame :: GuiObject).Visible = not hideTextDuringRise
	end
	local pos = relicInfo.Position
	relicInfo.Position = UDim2.new(pos.X.Scale, pos.X.Offset, RELIC_INFO_START_Y, pos.Y.Offset)
	relicInfo.Visible = false
end

local function playRelicInfoRise(session: ActiveSession, relicInfo: GuiObject, hideTextDuringRise: boolean): ()
	local textFrame = relicInfo:FindFirstChild("Text")
	if textFrame and textFrame:IsA("GuiObject") then
		(textFrame :: GuiObject).Visible = not hideTextDuringRise
	end

	local startPos = relicInfo.Position
	relicInfo.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset, RELIC_INFO_START_Y, startPos.Y.Offset)
	relicInfo.Visible = true

	local targetPos = UDim2.new(startPos.X.Scale, startPos.X.Offset, RELIC_INFO_END_Y, startPos.Y.Offset)
	local tw = TweenService:Create(
		relicInfo,
		TweenInfo.new(RELIC_INFO_RISE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = targetPos }
	)
	tw:Play()
	tw.Completed:Wait()

	if session.skipped then
		relicInfo.Visible = false
		return
	end

	if hideTextDuringRise and textFrame and textFrame:IsA("GuiObject") then
		(textFrame :: GuiObject).Visible = true
	end
end

local function waitForTap(session: ActiveSession, ignoreSkipped: boolean?): ()
	if session.skipped and not ignoreSkipped then
		return
	end
	session.waitingTap = true
	local done = false
	session.resumeTap = function()
		if done then
			return
		end
		done = true
		session.waitingTap = false
		session.resumeTap = nil
	end

	while not done and (ignoreSkipped or not session.skipped) and session.token == sessionToken do
		task.wait()
	end

	session.waitingTap = false
	session.resumeTap = nil
end

local function signalTap(session: ActiveSession)
	if session.resumeTap then
		session.resumeTap()
	end
end

local function playSingleReveal(session: ActiveSession, refs: any, result: SummonRelicResult, isMulti: boolean)
	resetChest(refs)
	setVisible(refs.relicList, false)
	if refs.relicInfo then
		prepareRelicInfoHidden(refs.relicInfo, isMulti)
	end

	if refs.chestClose then
		playChestShake(session, refs.chestClose)
	end
	if session.skipped then
		return
	end

	openChest(refs)
	if not isMulti then
		setTxtDesc(refs, getTapCloseText())
	end
	if refs.relicInfo then
		bindRelicInfo(refs.relicInfo, result)
		playRelicInfoRise(session, refs.relicInfo, isMulti)
	end
end

local function playSummary(session: ActiveSession, refs: any, slots: { GuiObject }, results: { SummonRelicResult })
	local stampInstant = session.skipped
	session.skipped = false
	session.inSummary = true
	setVisible(refs.chest, true)
	openChest(refs)
	setVisible(refs.relicInfo, false)
	setVisible(refs.btnSkip, false)

	resetRelicListSlots(slots)
	setVisible(refs.relicList, true)

	setTxtDesc(refs, getTapCloseText())

	for i, slot in slots do
		local result = results[i]
		if result then
			bindRelicToSlotRoot(slot, result)
			slot.Visible = true
		end
		if not stampInstant and i < #results then
			task.wait(RELIC_LIST_STAMP_INTERVAL)
		end
		if session.token ~= sessionToken then
			return
		end
	end
end

local function runSequence(
	session: ActiveSession,
	refs: any,
	slots: { GuiObject },
	results: { SummonRelicResult },
	onFinished: (() -> ())?
)
	local isMulti = #results > 1

	if isMulti then
		setVisible(refs.btnSkip, true)
	end

	for i, result in ipairs(results) do
		if session.skipped or session.token ~= sessionToken then
			break
		end

		if isMulti then
			setTxtDesc(refs, getTapNextText())
		end

		playSingleReveal(session, refs, result, isMulti)
		if session.skipped or session.token ~= sessionToken then
			break
		end

		waitForTap(session)
		if session.skipped or session.token ~= sessionToken then
			break
		end

		if isMulti and refs.relicInfo and i < #results then
			prepareRelicInfoHidden(refs.relicInfo, true)
			resetChest(refs)
		end
	end

	if isMulti then
		playSummary(session, refs, slots, results)
		waitForTap(session, true)
	end

	session.close()
	if onFinished then
		onFinished()
	end
end

function RelicSummonPopup.play(results: { SummonRelicResult }, onFinished: (() -> ())?)
	if typeof(results) ~= "table" or #results == 0 then
		warn("[RelicSummonPopup] 잘못된 results")
		return
	end

	if activeSession then
		activeSession.skipped = true
		if activeSession.cancelShake then
			activeSession.cancelShake()
		end
		if activeSession.resumeTap then
			activeSession.resumeTap()
		end
		activeSession.close()
	end

	local rootGui = getRelicSummonPopupRoot()
	if not rootGui then
		warn("[RelicSummonPopup] Content.RelicSummonPopup 없음")
		return
	end
	StringBinder.applySubtreeOnce(rootGui)

	local refs = getUiRefs(rootGui)
	if not refs.backgroundBtn then
		warn("[RelicSummonPopup] BackgroundButton 없음")
		return
	end
	if not refs.relicInfo then
		warn("[RelicSummonPopup] Container.RelicInfo 없음")
		return
	end
	if not refs.txtDesc then
		warn(
			"[RelicSummonPopup] TxtDesc (TextLabel) 없음 — "
				.. rootGui:GetFullName()
				.. " 하위에 Name=TxtDesc 인 TextLabel 확인"
		)
	end

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[RelicSummonPopup] Content 없음")
		return
	end

	local slots = collectRelicSlots(refs.layout)
	local contentGui = content :: GuiObject
	local prevContentActive = contentGui.Active
	local prevRootActive = rootGui.Active
	local wasRootVis = rootGui.Visible

	contentGui.Active = false
	rootGui.Active = false

	sessionToken += 1
	local myToken = sessionToken

	local closed = false
	local connections: { RBXScriptConnection } = {}

	local session: ActiveSession = {
		token = myToken,
		skipped = false,
		inSummary = false,
		waitingTap = false,
		resumeTap = nil,
		cancelShake = nil,
		close = function() end,
	}

	local function close()
		if closed then
			return
		end
		closed = true
		if session.cancelShake then
			session.cancelShake()
		end
		for _, c in ipairs(connections) do
			c:Disconnect()
		end
		resetChest(refs)
		setVisible(refs.relicInfo, false)
		setVisible(refs.relicList, false)
		setVisible(refs.btnSkip, false)
		resetRelicListSlots(slots)
		rootGui.Visible = wasRootVis
		contentGui.Active = prevContentActive
		rootGui.Active = prevRootActive
		PopupManager.popPopup()
		if activeSession == session then
			activeSession = nil
		end
	end

	session.close = close

	if not PopupManager.pushPopup({
		dim = true,
		blockInput = true,
		close = close,
		closeOthers = false,
		playEntranceAnimation = false,
		rootGui = rootGui,
	}) then
		contentGui.Active = prevContentActive
		rootGui.Active = prevRootActive
		return
	end

	rootGui.Visible = true
	bindTxtDesc(rootGui, refs)

	resetChest(refs)
	setVisible(refs.relicInfo, false)
	setVisible(refs.relicList, false)
	setVisible(refs.btnSkip, false)
	resetRelicListSlots(slots)
	setTxtDesc(refs, "")

	prepareClickableButton(refs.backgroundBtn)
	table.insert(connections, refs.backgroundBtn.Activated:Connect(function()
		if session.waitingTap or session.inSummary then
			signalTap(session)
		end
	end))

	if refs.btnSkip then
		prepareClickableButton(refs.btnSkip)
		table.insert(connections, refs.btnSkip.Activated:Connect(function()
			if session.inSummary or #results <= 1 then
				return
			end
			session.skipped = true
			if session.cancelShake then
				session.cancelShake()
			end
			setVisible(refs.relicInfo, false)
			signalTap(session)
		end))
	end

	activeSession = session

	task.spawn(function()
		runSequence(session, refs, slots, results, onFinished)
	end)
end

function RelicSummonPopup.close()
	if activeSession then
		activeSession.close()
	end
end

function RelicSummonPopup.init()
	if initialized then
		return
	end
	initialized = true
	print("[RelicSummonPopup] 초기화 완료")
end

return RelicSummonPopup
