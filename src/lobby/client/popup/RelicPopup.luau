--[[
	RelicPopup (lobby client)

	GUI tree: PopupScreenGui.Content.RelicPopup (GuiObject)
		Bottom.Tabs.BtnCollection / BtnSet — TabBg(ImageLabel), TxtBtnName
		Top.CloseButton
		Container.ScrollingContainer
			RelicCollectionGroup (원본 = D등급, C/B/A는 Clone)
				RelicItems.RelicItem (원본 = 첫 유물, 나머지는 Clone)
				Grade.Root.TxtGrade
			RelicSetGroup (원본 = RelicHelper.getSetIds()[1], 나머지는 Clone — 갯수 = RelicData.sets 요소 수)
				Set.Root.TxtSet — StringData[setId](=SetD/SetC/SetB/SetA)로 표시
				Set.Root.Bg — RelicHelper.getGradeSlotColor(set.grade)로 등급별 틴트 (RelicCollectionGroup.Grade.Root.Bg와 동일)
				RelicItems.RelicItem — RelicCollectionGroup과 동일한 방식(populateRelicItemsGeneric 공용), 단 아이템 수에 따른 그룹 사이즈 조절(applyGroupSize)은 미적용
				SetOptions.TxtOption_1~4 — set.effect.levels[1..4]. 세트 소속 유물 전원이 requiredRelicLevel
				  이상이면 "[세트 완료] <효과문>"(TextColor3 0,0,0), 미달이면 "[All Lv.N] <효과문>"(127,127,127)

	Tabs: 팝업 진입 시 기본 탭 = Collection. BtnCollection/BtnSet 클릭 시 서로의 TabBg.ImageColor3를
	활성(251,155,27)/비활성(167,106,69)으로 토글하고, 해당 탭의 그룹 캐시만 Visible = true로 전환한다.

	RelicItem.Btn 클릭 → RelicInfo 활성화 / RelicInfo.Main.BtnClose·RelicPopup 닫기 → RelicInfo 비활성화
	RelicInfo.Grade — RelicCollectionGroup.Grade와 동일 (setTxtGrade/setGradeBg 재사용)
	RelicInfo.Main.RelicItem — RelicCollectionGroup.RelicItem과 동일 구조 (bindRelicItemProgress 재사용)
	RelicInfo.Main.TxtRelicName — RelicDefinition.name(=StringData 키)로 표시
	RelicInfo.Main.BtnLevelUp — RelicHelper.requestLevelUp(relicId) 호출, 레벨업 불가 시 무반응. Enable/Disable은 레벨업 가능 여부로 토글
		레벨업 성공 시 RelicPopup은 유지한 채 LevelUpPopup을 위에 오버레이 (Dim이 RelicPopup과 LevelUpPopup 사이에 위치)
	RelicInfo.Main.ScrollView(CanvasGroup).ScrollingFrame.OptionItem — Lv.1~getMaxLevel() 개수만큼 최초 1회 생성/캐싱, Disabled는 해당 유물 레벨 미달 시 표시
		OptionSlot.TxtOption — 해당 레벨의 RelicDefinition.abilities 문장(OptionHelper.formatText, 능력 2개면 줄바꿈으로 결합)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)
local StringBinder = require(Shared.Helpers.StringBinder)
local StringHelper = require(Shared.Helpers.StringHelper)
local OptionHelper = require(Shared.Helpers.OptionHelper)
local RelicHelper = require(Shared.Helpers.RelicHelper)
local RelicClient = require(script.Parent.Parent.RelicClient)
local LevelUpPopup = require(script.Parent.LevelUpPopup)

local RelicPopup = {}

local POPUP_ROOT_NAME = "RelicPopup"
local RELIC_INFO_NAME = "RelicInfo"
local GRADE_ORDER = { "D", "C", "B", "A" }
local LOCALE = "kr"

local TAB_COLLECTION = "Collection"
local TAB_SET = "Set"
local TAB_COLOR_ACTIVE = Color3.fromRGB(251, 155, 27)
local TAB_COLOR_INACTIVE = Color3.fromRGB(167, 106, 69)

local initialized = false
local activeSession: { close: () -> () }? = nil

local groupsBuilt = false
local groupCache: { [string]: GuiObject } = {}
local itemCache: { [number]: GuiObject } = {} -- relicId → RelicItem

local setGroupsBuilt = false
local setGroupCache: { [string]: GuiObject } = {} -- setId → RelicSetGroup
local setItemCache: { { relicId: number, item: GuiObject } } = {} -- RelicSetGroup.RelicItems 내부 아이템

local currentRelicId: number? = nil
local currentCanLevelUp = false

local optionItemsBuilt = false
local optionItemPool: { GuiObject } = {}

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

local function getRelicPopupRoot(): GuiObject?
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

local function getRelicInfoRoot(popupRoot: GuiObject): GuiObject?
	local infoInst = popupRoot:FindFirstChild(RELIC_INFO_NAME)
	if infoInst and infoInst:IsA("GuiObject") then
		return infoInst :: GuiObject
	end
	return nil
end

local function hideRelicInfo(popupRoot: GuiObject)
	local relicInfo = getRelicInfoRoot(popupRoot)
	if relicInfo then
		relicInfo.Visible = false
	end
end

local function bindRelicInfoCloseButtons(popupRoot: GuiObject, connections: { RBXScriptConnection })
	local relicInfo = getRelicInfoRoot(popupRoot)
	local main = relicInfo and relicInfo:FindFirstChild("Main")
	if not main then
		warn("[RelicPopup] RelicInfo.Main 없음 — 닫기 버튼 미연결")
		return
	end

	local btnInst = main:FindFirstChild("BtnClose")
	if btnInst and btnInst:IsA("GuiButton") then
		local btn = btnInst :: GuiButton
		prepareClickableButton(btn)
		table.insert(connections, btn.Activated:Connect(function()
			hideRelicInfo(popupRoot)
		end))
	else
		warn("[RelicPopup] RelicInfo.Main.BtnClose 없음")
	end
end

local function getGradeLabel(grade: string): string
	local key = "RelicGrade_" .. grade
	local text = StringHelper.get(key, LOCALE)
	if text == key then
		return grade
	end
	return text
end

local function getLayoutScale(count: number): (number, number)
	if count <= 5 then
		return 0.3, 1
	elseif count <= 10 then
		return 0.6, 0.5
	else
		return 0.9, 0.333
	end
end

local function applyGroupSize(group: GuiObject, count: number)
	local sizeY, cellY = getLayoutScale(count)
	local size = group.Size
	group.Size = UDim2.new(size.X.Scale, size.X.Offset, sizeY, size.Y.Offset)

	local relicItems = group:FindFirstChild("RelicItems")
	local grid = relicItems and relicItems:FindFirstChildOfClass("UIGridLayout")
	if grid then
		local cell = grid.CellSize
		grid.CellSize = UDim2.new(cell.X.Scale, cell.X.Offset, cellY, cell.Y.Offset)
	end
end

local function relicsByGrade(): { [string]: { RelicHelper.RelicDefinition } }
	local buckets: { [string]: { RelicHelper.RelicDefinition } } = {
		D = {},
		C = {},
		B = {},
		A = {},
	}
	for _, relicId in RelicHelper.getRelicIds() do
		local relic = RelicHelper.getRelic(relicId)
		if relic and buckets[relic.grade] then
			table.insert(buckets[relic.grade], relic)
		end
	end
	return buckets
end

local FILL_COLOR_MID = Color3.fromRGB(255, 251, 7) -- 레벨업 불가 && MAX 미만
local FILL_COLOR_MAX = Color3.fromRGB(25, 199, 134) -- 레벨업 가능 || MAX

local function getFillColorForLevel(canLevelUp: boolean, level: number, maxLevel: number): Color3
	if canLevelUp or level >= maxLevel then
		return FILL_COLOR_MAX
	end
	return FILL_COLOR_MID
end

local function bindRelicInfo(item: GuiObject, relicId: number, level: number, maxLevel: number)
	local relicInfo = item:FindFirstChild("RelicInfo")
	if not relicInfo then
		return
	end

	local relic = RelicHelper.getRelic(relicId)
	if relic then
		local slot = relicInfo:FindFirstChild("Slot")
		if slot then
			RelicHelper.applyGradeSlotBg(slot, relic.grade)
		end

		local relicIconInst = RelicHelper.findRelicIconImageLabel(relicInfo)
		if relicIconInst then
			RelicHelper.applyRelicIconToImageLabel(relicIconInst, relicId)
		end
	end

	local txtLevel = relicInfo:FindFirstChild("TxtLevel")
	if txtLevel and txtLevel:IsA("TextLabel") then
		(txtLevel :: TextLabel).Text = "Lv." .. tostring(math.clamp(level, 0, maxLevel))
	end
end

local function bindRelicItemProgress(item: GuiObject, relicId: number, progress: RelicHelper.RelicProgress)
	local entry = progress[relicId]
	local level = if entry then entry.level else 0
	local xp = if entry then entry.xp else 0
	local maxLevel = RelicHelper.getMaxLevel()
	local active = level >= 1
	local required = RelicHelper.getXpRequiredForNextLevel(level)
	local canLevelUp = RelicHelper.canRelicLevelUp(level, xp)

	local lockIcon = item:FindFirstChild("LockIcon")
	if lockIcon and lockIcon:IsA("GuiObject") then
		(lockIcon :: GuiObject).Visible = not active
	end

	local upgradeIcon = item:FindFirstChild("UpgradeIcon")
	if upgradeIcon and upgradeIcon:IsA("GuiObject") then
		local upgradeIconGui = upgradeIcon :: GuiObject
		upgradeIconGui.Visible = canLevelUp
	end

	bindRelicInfo(item, relicId, level, maxLevel)

	local xpBar = item:FindFirstChild("XPBar")
	if not (xpBar and xpBar:IsA("GuiObject")) then
		return
	end

	local fill = xpBar:FindFirstChild("Fill")
	local txtProgress = xpBar:FindFirstChild("TxtProgress")

	if fill and fill:IsA("GuiObject") then
		(fill :: GuiObject).BackgroundColor3 = getFillColorForLevel(canLevelUp, level, maxLevel)
	end

	if level >= maxLevel then
		if fill and fill:IsA("GuiObject") then
			local fillGui = fill :: GuiObject
			fillGui.Size = UDim2.new(1, fillGui.Size.X.Offset, fillGui.Size.Y.Scale, fillGui.Size.Y.Offset)
		end
		if txtProgress and txtProgress:IsA("TextLabel") then
			(txtProgress :: TextLabel).Text = "MAX"
		end
		return
	end

	local ratio = if required and required > 0 then math.clamp(xp / required, 0, 1) else 0
	if fill and fill:IsA("GuiObject") then
		local fillGui = fill :: GuiObject
		fillGui.Size = UDim2.new(ratio, fillGui.Size.X.Offset, fillGui.Size.Y.Scale, fillGui.Size.Y.Offset)
	end
	if txtProgress and txtProgress:IsA("TextLabel") then
		if required then
			(txtProgress :: TextLabel).Text = string.format("%d/%d", xp, required)
		else
			(txtProgress :: TextLabel).Text = tostring(xp)
		end
	end
end

local SET_OPTION_COLOR_MET = Color3.fromRGB(0, 0, 0)
local SET_OPTION_COLOR_UNMET = Color3.fromRGB(127, 127, 127)

local function findSetOptionTxt(group: GuiObject, level: number): TextLabel?
	local setOptions = group:FindFirstChild("SetOptions")
	local txtInst = setOptions and setOptions:FindFirstChild("TxtOption_" .. tostring(level))
	if txtInst and txtInst:IsA("TextLabel") then
		return txtInst :: TextLabel
	end
	return nil
end

local function isSetLevelMet(set: RelicHelper.RelicSetDefinition, requiredRelicLevel: number, progress: RelicHelper.RelicProgress): boolean
	for _, relicId in set.relicIds do
		local entry = progress[relicId]
		local level = if entry then entry.level else 0
		if level < requiredRelicLevel then
			return false
		end
	end
	return true
end

local function refreshSetGroupOptions(setId: string, group: GuiObject, progress: RelicHelper.RelicProgress)
	local set = RelicHelper.getSet(setId)
	if not set then
		return
	end

	for level, entry in set.effect.levels do
		local txt = findSetOptionTxt(group, level)
		if not txt then
			continue
		end
		local optionText = OptionHelper.formatText(set.effect.type, entry.stat1, nil, LOCALE) or ""
		local met = isSetLevelMet(set, entry.requiredRelicLevel, progress)
		if met then
			txt.Text = string.format("[세트 완료] %s", optionText)
			txt.TextColor3 = SET_OPTION_COLOR_MET
		else
			txt.Text = string.format("[All Lv.%d] %s", entry.requiredRelicLevel, optionText)
			txt.TextColor3 = SET_OPTION_COLOR_UNMET
		end
	end
end

local function refreshAllItemProgress()
	local progress = RelicHelper.fetchRelicProgress()
	for relicId, item in itemCache do
		bindRelicItemProgress(item, relicId, progress)
	end
	for _, entry in setItemCache do
		bindRelicItemProgress(entry.item, entry.relicId, progress)
	end
	for setId, group in setGroupCache do
		refreshSetGroupOptions(setId, group, progress)
	end
	RelicClient.refreshNotification(progress)
end

local function setTxtGrade(group: GuiObject, grade: string)
	local gradeFrame = group:FindFirstChild("Grade")
	local root = gradeFrame and gradeFrame:FindFirstChild("Root")
	local txtInst = root and root:FindFirstChild("TxtGrade")
	if txtInst and txtInst:IsA("TextLabel") then
		(txtInst :: TextLabel).Text = getGradeLabel(grade)
	else
		warn("[RelicPopup] Grade.Root.TxtGrade 없음 (grade=", grade, ")")
	end
end

local function setGradeBg(group: GuiObject, grade: string)
	local gradeFrame = group:FindFirstChild("Grade")
	local root = gradeFrame and gradeFrame:FindFirstChild("Root")
	local bgInst = root and root:FindFirstChild("Bg")
	if bgInst and bgInst:IsA("ImageLabel") then
		local color = RelicHelper.getGradeSlotColor(grade)
		if color then
			(bgInst :: ImageLabel).ImageColor3 = color
		end
	else
		warn("[RelicPopup] Grade.Root.Bg 없음 (grade=", grade, ")")
	end
end

local function getRelicInfoMain(relicInfo: GuiObject): GuiObject?
	local mainInst = relicInfo:FindFirstChild("Main")
	if mainInst and mainInst:IsA("GuiObject") then
		return mainInst :: GuiObject
	end
	return nil
end

local function refreshLevelUpButton(relicInfo: GuiObject, canLevelUp: boolean)
	local main = getRelicInfoMain(relicInfo)
	local btnInst = main and main:FindFirstChild("BtnLevelUp")
	if not btnInst then
		warn("[RelicPopup] RelicInfo.Main.BtnLevelUp 없음")
		return
	end

	local enableInst = btnInst:FindFirstChild("Enable")
	if enableInst and enableInst:IsA("GuiObject") then
		(enableInst :: GuiObject).Visible = canLevelUp
	end

	local disableInst = btnInst:FindFirstChild("Disable")
	if disableInst and disableInst:IsA("GuiObject") then
		(disableInst :: GuiObject).Visible = not canLevelUp
	end
end

local function ensureOptionItemsBuilt(relicInfo: GuiObject): boolean
	if optionItemsBuilt then
		return #optionItemPool > 0
	end

	local main = getRelicInfoMain(relicInfo)
	local scrollViewInst = main and main:FindFirstChild("ScrollView")
	if not (scrollViewInst and scrollViewInst:IsA("GuiObject")) then
		warn("[RelicPopup] RelicInfo.Main.ScrollView 없음")
		return false
	end
	local scrollingInst = (scrollViewInst :: GuiObject):FindFirstChild("ScrollingFrame")
	if not (scrollingInst and scrollingInst:IsA("GuiObject")) then
		warn("[RelicPopup] RelicInfo.Main.ScrollView.ScrollingFrame 없음")
		return false
	end
	local scrolling = scrollingInst :: GuiObject

	local templateInst = scrolling:FindFirstChild("OptionItem")
	if not (templateInst and templateInst:IsA("GuiObject")) then
		warn("[RelicPopup] ScrollingFrame.OptionItem 템플릿 없음")
		return false
	end
	local template = templateInst :: GuiObject

	local maxLevel = RelicHelper.getMaxLevel()
	for level = 1, maxLevel do
		local optionItem: GuiObject
		if level == 1 then
			optionItem = template
		else
			optionItem = template:Clone()
			optionItem.Parent = scrolling
		end
		optionItem.Name = "OptionItem_" .. tostring(level)
		optionItem.LayoutOrder = level
		optionItem.Visible = true

		local txtLevelInst = optionItem:FindFirstChild("TxtLevel")
		if txtLevelInst and txtLevelInst:IsA("TextLabel") then
			(txtLevelInst :: TextLabel).Text = "Lv." .. tostring(level)
		end

		optionItemPool[level] = optionItem
	end

	optionItemsBuilt = true
	return true
end

local TXT_OPTION_SIZE_Y_SCALE_SINGLE = 0.5
local TXT_OPTION_SIZE_Y_SCALE_MULTI = 0.95

local function buildOptionTextForLevel(abilities: { RelicHelper.RelicAbility }, level: number): (string, number)
	local lines: { string } = {}
	for _, ability in abilities do
		local stat = ability.levels[level]
		if stat then
			local text = OptionHelper.formatText(ability.type, stat.stat1, stat.stat2, LOCALE)
			if text then
				table.insert(lines, text)
			end
		end
	end
	return table.concat(lines, "\n"), #lines
end

local function refreshOptionItemsForLevel(relicInfo: GuiObject, level: number, abilities: { RelicHelper.RelicAbility })
	if not ensureOptionItemsBuilt(relicInfo) then
		return
	end
	for optionLevel, optionItem in ipairs(optionItemPool) do
		local disabledInst = optionItem:FindFirstChild("Disabled")
		if disabledInst and disabledInst:IsA("GuiObject") then
			(disabledInst :: GuiObject).Visible = level < optionLevel
		end

		local optionSlot = optionItem:FindFirstChild("OptionSlot")
		local txtOption = optionSlot and optionSlot:FindFirstChild("TxtOption")
		if txtOption and txtOption:IsA("TextLabel") then
			local txt = txtOption :: TextLabel
			local text, count = buildOptionTextForLevel(abilities, optionLevel)
			txt.Text = text
			local sizeYScale = if count >= 2 then TXT_OPTION_SIZE_Y_SCALE_MULTI else TXT_OPTION_SIZE_Y_SCALE_SINGLE
			local size = txt.Size
			txt.Size = UDim2.new(size.X.Scale, size.X.Offset, sizeYScale, size.Y.Offset)
		end
	end
end

local function refreshRelicInfoContent(popupRoot: GuiObject, relicId: number)
	local relicInfo = getRelicInfoRoot(popupRoot)
	if not relicInfo then
		return
	end

	local relic = RelicHelper.getRelic(relicId)
	if not relic then
		warn("[RelicPopup] RelicInfo: 유물 정보 없음 (relicId=", relicId, ")")
		return
	end

	setTxtGrade(relicInfo, relic.grade)
	setGradeBg(relicInfo, relic.grade)

	local main = getRelicInfoMain(relicInfo)
	if not main then
		warn("[RelicPopup] RelicInfo.Main 없음")
		return
	end

	local txtNameInst = main:FindFirstChild("TxtRelicName")
	if txtNameInst and txtNameInst:IsA("TextLabel") then
		(txtNameInst :: TextLabel).Text = StringHelper.get(relic.name, LOCALE)
	else
		warn("[RelicPopup] RelicInfo.Main.TxtRelicName 없음")
	end

	local progress = RelicHelper.fetchRelicProgress()
	local entry = progress[relicId]
	local level = if entry then entry.level else 0
	local xp = if entry then entry.xp else 0

	local mainItemInst = main:FindFirstChild("RelicItem")
	if mainItemInst and mainItemInst:IsA("GuiObject") then
		bindRelicItemProgress(mainItemInst :: GuiObject, relicId, progress)
	else
		warn("[RelicPopup] RelicInfo.Main.RelicItem 없음")
	end

	currentCanLevelUp = RelicHelper.canRelicLevelUp(level, xp)
	refreshLevelUpButton(relicInfo, currentCanLevelUp)
	refreshOptionItemsForLevel(relicInfo, level, relic.abilities)
end

local function showRelicInfo(popupRoot: GuiObject, relicId: number)
	local relicInfo = getRelicInfoRoot(popupRoot)
	if not relicInfo then
		warn("[RelicPopup] RelicInfo 없음")
		return
	end
	currentRelicId = relicId
	refreshRelicInfoContent(popupRoot, relicId)
	relicInfo.Visible = true
end

local function bindRelicInfoLevelUpButton(popupRoot: GuiObject, connections: { RBXScriptConnection })
	local relicInfo = getRelicInfoRoot(popupRoot)
	local main = relicInfo and getRelicInfoMain(relicInfo)
	local btnInst = main and main:FindFirstChild("BtnLevelUp")
	if not (btnInst and btnInst:IsA("GuiButton")) then
		warn("[RelicPopup] RelicInfo.Main.BtnLevelUp 없음")
		return
	end
	local btn = btnInst :: GuiButton
	prepareClickableButton(btn)
	table.insert(connections, btn.Activated:Connect(function()
		if not currentCanLevelUp or not currentRelicId then
			return
		end
		local relicId = currentRelicId :: number
		local result = RelicHelper.requestLevelUp(relicId)
		if not result then
			return
		end
		refreshAllItemProgress()
		refreshRelicInfoContent(popupRoot, relicId)
		task.defer(function()
			LevelUpPopup.open(result.level)
		end)
	end))
end

local function wireRelicItemButton(item: GuiObject, relicId: number)
	local btnInst = item:FindFirstChild("Btn")
	if not (btnInst and btnInst:IsA("GuiButton")) then
		warn("[RelicPopup] RelicItem.Btn 없음")
		return
	end
	local btn = btnInst :: GuiButton
	prepareClickableButton(btn)
	btn.Activated:Connect(function()
		local popupRoot = getRelicPopupRoot()
		if not popupRoot then
			return
		end
		showRelicInfo(popupRoot, relicId)
	end)
end

local function populateRelicItemsGeneric(
	group: GuiObject,
	relics: { RelicHelper.RelicDefinition },
	onItem: (GuiObject, RelicHelper.RelicDefinition) -> ()
)
	local relicItemsInst = group:FindFirstChild("RelicItems")
	if not (relicItemsInst and relicItemsInst:IsA("GuiObject")) then
		warn("[RelicPopup] RelicItems 없음")
		return
	end
	local relicItems = relicItemsInst :: GuiObject

	local itemTemplateInst = relicItems:FindFirstChild("RelicItem")
	if not (itemTemplateInst and itemTemplateInst:IsA("GuiObject")) then
		warn("[RelicPopup] RelicItem 템플릿 없음")
		return
	end
	local itemTemplate = itemTemplateInst :: GuiObject

	if #relics == 0 then
		itemTemplate.Visible = false
		return
	end

	for itemOrder, relic in ipairs(relics) do
		local item: GuiObject
		if itemOrder == 1 then
			item = itemTemplate
			item.Name = "RelicItem_" .. tostring(relic.id)
		else
			item = itemTemplate:Clone()
			item.Name = "RelicItem_" .. tostring(relic.id)
			item.Parent = relicItems
		end
		item.LayoutOrder = itemOrder
		item.Visible = true
		wireRelicItemButton(item, relic.id)
		onItem(item, relic)
	end
end

local function populateRelicItems(group: GuiObject, relics: { RelicHelper.RelicDefinition })
	populateRelicItemsGeneric(group, relics, function(item, relic)
		itemCache[relic.id] = item
	end)
end

local function populateSetRelicItems(group: GuiObject, relics: { RelicHelper.RelicDefinition })
	populateRelicItemsGeneric(group, relics, function(item, relic)
		table.insert(setItemCache, { relicId = relic.id, item = item })
	end)
end

local function ensureGroupsBuilt(rootGui: GuiObject): boolean
	if groupsBuilt then
		return next(groupCache) ~= nil
	end

	local container = rootGui:FindFirstChild("Container")
	local scrollingInst = container and container:FindFirstChild("ScrollingContainer")
	if not (scrollingInst and scrollingInst:IsA("GuiObject")) then
		warn("[RelicPopup] Container.ScrollingContainer 없음")
		return false
	end
	local scrolling = scrollingInst :: GuiObject

	local templateGroupInst = scrolling:FindFirstChild("RelicCollectionGroup")
	if not (templateGroupInst and templateGroupInst:IsA("GuiObject")) then
		warn("[RelicPopup] RelicCollectionGroup 템플릿 없음")
		return false
	end
	local templateGroup = templateGroupInst :: GuiObject

	local byGrade = relicsByGrade()

	-- 1) RelicCollectionGroup: 원본 = D, C/B/A는 Clone (아이템 채우기 전에 전부 생성)
	for gradeOrder, grade in ipairs(GRADE_ORDER) do
		local group: GuiObject
		if gradeOrder == 1 then
			group = templateGroup
		else
			group = templateGroup:Clone()
			group.Parent = scrolling
		end
		group.Name = "RelicCollectionGroup_" .. grade
		group.LayoutOrder = gradeOrder
		group.Visible = true
		groupCache[grade] = group
	end

	-- 2) 각 그룹에 RelicItem 채우기 + 등급 라벨/사이즈
	for _, grade in ipairs(GRADE_ORDER) do
		local group = groupCache[grade]
		local relics = byGrade[grade] or {}
		setTxtGrade(group, grade)
		setGradeBg(group, grade)
		populateRelicItems(group, relics)
		applyGroupSize(group, #relics)
	end

	groupsBuilt = true
	return true
end

local function setTxtSet(group: GuiObject, setId: string)
	local setFrame = group:FindFirstChild("Set")
	local root = setFrame and setFrame:FindFirstChild("Root")
	local txtInst = root and root:FindFirstChild("TxtSet")
	if txtInst and txtInst:IsA("TextLabel") then
		(txtInst :: TextLabel).Text = StringHelper.get(setId, LOCALE)
	else
		warn("[RelicPopup] Set.Root.TxtSet 없음 (setId=", setId, ")")
	end
end

local function setSetBg(group: GuiObject, grade: string)
	local setFrame = group:FindFirstChild("Set")
	local root = setFrame and setFrame:FindFirstChild("Root")
	local bgInst = root and root:FindFirstChild("Bg")
	if bgInst and bgInst:IsA("ImageLabel") then
		local color = RelicHelper.getGradeSlotColor(grade)
		if color then
			(bgInst :: ImageLabel).ImageColor3 = color
		end
	else
		warn("[RelicPopup] Set.Root.Bg 없음 (grade=", grade, ")")
	end
end

local function relicsForSet(setId: string): { RelicHelper.RelicDefinition }
	local set = RelicHelper.getSet(setId)
	local relics: { RelicHelper.RelicDefinition } = {}
	if not set then
		return relics
	end
	for _, relicId in set.relicIds do
		local relic = RelicHelper.getRelic(relicId)
		if relic then
			table.insert(relics, relic)
		end
	end
	return relics
end

local function ensureSetGroupsBuilt(rootGui: GuiObject): boolean
	if setGroupsBuilt then
		return next(setGroupCache) ~= nil
	end

	local container = rootGui:FindFirstChild("Container")
	local scrollingInst = container and container:FindFirstChild("ScrollingContainer")
	if not (scrollingInst and scrollingInst:IsA("GuiObject")) then
		warn("[RelicPopup] Container.ScrollingContainer 없음")
		return false
	end
	local scrolling = scrollingInst :: GuiObject

	local templateGroupInst = scrolling:FindFirstChild("RelicSetGroup")
	if not (templateGroupInst and templateGroupInst:IsA("GuiObject")) then
		warn("[RelicPopup] RelicSetGroup 템플릿 없음")
		return false
	end
	local templateGroup = templateGroupInst :: GuiObject

	local setIds = RelicHelper.getSetIds()
	if #setIds == 0 then
		warn("[RelicPopup] RelicData.sets 비어있음")
	end

	-- 1) RelicSetGroup: 원본 = 첫 세트, 나머지는 Clone (아이템 채우기 전에 전부 생성 — RelicCollectionGroup과 동일)
	for setOrder, setId in ipairs(setIds) do
		local group: GuiObject
		if setOrder == 1 then
			group = templateGroup
		else
			group = templateGroup:Clone()
			group.Parent = scrolling
		end
		group.Name = "RelicSetGroup_" .. setId
		group.LayoutOrder = setOrder
		group.Visible = true
		setGroupCache[setId] = group
	end

	-- 2) 각 그룹에 라벨/등급 배경/RelicItem 채우기 (RelicItem 갯수에 따른 그룹 사이즈 조절은 미적용)
	for _, setId in ipairs(setIds) do
		local group = setGroupCache[setId]
		local set = RelicHelper.getSet(setId)
		setTxtSet(group, setId)
		if set then
			setSetBg(group, set.grade)
		end
		populateSetRelicItems(group, relicsForSet(setId))
	end

	if #setIds == 0 then
		templateGroup.Visible = false
	end

	setGroupsBuilt = true
	return true
end

local function getTabsFrame(popupRoot: GuiObject): GuiObject?
	local bottom = popupRoot:FindFirstChild("Bottom")
	local tabsInst = bottom and bottom:FindFirstChild("Tabs")
	if tabsInst and tabsInst:IsA("GuiObject") then
		return tabsInst :: GuiObject
	end
	return nil
end

local function applyTabBgColor(tabsFrame: GuiObject, btnName: string, active: boolean)
	local btnInst = tabsFrame:FindFirstChild(btnName)
	if not btnInst then
		warn("[RelicPopup] Tabs." .. btnName .. " 없음")
		return
	end
	local color = if active then TAB_COLOR_ACTIVE else TAB_COLOR_INACTIVE
	local tabBgInst = btnInst:FindFirstChild("TabBg")
	if tabBgInst and tabBgInst:IsA("ImageLabel") then
		(tabBgInst :: ImageLabel).ImageColor3 = color
	elseif tabBgInst and tabBgInst:IsA("ImageButton") then
		(tabBgInst :: ImageButton).ImageColor3 = color
	else
		warn("[RelicPopup] Tabs." .. btnName .. ".TabBg 없음")
	end
end

local function setActiveTab(popupRoot: GuiObject, tab: string)
	local tabsFrame = getTabsFrame(popupRoot)
	if tabsFrame then
		applyTabBgColor(tabsFrame, "BtnCollection", tab == TAB_COLLECTION)
		applyTabBgColor(tabsFrame, "BtnSet", tab == TAB_SET)
	end

	local showCollection = tab == TAB_COLLECTION
	for _, group in groupCache do
		group.Visible = showCollection
	end
	for _, group in setGroupCache do
		group.Visible = not showCollection
	end
end

local function bindTabButtons(popupRoot: GuiObject, connections: { RBXScriptConnection })
	local tabsFrame = getTabsFrame(popupRoot)
	if not tabsFrame then
		warn("[RelicPopup] Bottom.Tabs 없음")
		return
	end

	local collectionBtnInst = tabsFrame:FindFirstChild("BtnCollection")
	if collectionBtnInst and collectionBtnInst:IsA("GuiButton") then
		local btn = collectionBtnInst :: GuiButton
		prepareClickableButton(btn)
		table.insert(connections, btn.Activated:Connect(function()
			setActiveTab(popupRoot, TAB_COLLECTION)
		end))
	else
		warn("[RelicPopup] Tabs.BtnCollection 없음")
	end

	local setBtnInst = tabsFrame:FindFirstChild("BtnSet")
	if setBtnInst and setBtnInst:IsA("GuiButton") then
		local btn = setBtnInst :: GuiButton
		prepareClickableButton(btn)
		table.insert(connections, btn.Activated:Connect(function()
			setActiveTab(popupRoot, TAB_SET)
		end))
	else
		warn("[RelicPopup] Tabs.BtnSet 없음")
	end
end

function RelicPopup.open(focusRelicId: number?, skipEntranceAnimation: boolean?)
	if activeSession then
		return
	end

	local rootGui = getRelicPopupRoot()
	if not rootGui then
		warn("[RelicPopup] Content.RelicPopup 없음")
		return
	end
	StringBinder.applySubtreeOnce(rootGui)

	if not ensureGroupsBuilt(rootGui) then
		return
	end
	if not ensureSetGroupsBuilt(rootGui) then
		return
	end
	refreshAllItemProgress()

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[RelicPopup] Content 없음")
		return
	end

	local top = rootGui:FindFirstChild("Top")
	local closeInst = top and top:FindFirstChild("CloseButton")
	if not (closeInst and closeInst:IsA("GuiButton")) then
		warn("[RelicPopup] Top.CloseButton 없음")
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
		hideRelicInfo(rootGui)
		for _, connection in ipairs(connections) do
			connection:Disconnect()
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

	hideRelicInfo(rootGui)

	rootGui.Visible = true
	if pushOptions.playEntranceAnimation then
		PopupManager.playBounceEntrance(rootGui)
	end

	prepareClickableButton(closeBtn)
	table.insert(connections, closeBtn.Activated:Connect(close))
	bindRelicInfoCloseButtons(rootGui, connections)
	bindRelicInfoLevelUpButton(rootGui, connections)
	bindTabButtons(rootGui, connections)
	setActiveTab(rootGui, TAB_COLLECTION)

	activeSession = { close = close }

	if focusRelicId then
		showRelicInfo(rootGui, focusRelicId)
	end
end

function RelicPopup.close()
	if activeSession then
		activeSession.close()
	end
end

function RelicPopup.init()
	if initialized then
		return
	end
	initialized = true
	print("[RelicPopup] 초기화 완료")
end

return RelicPopup
