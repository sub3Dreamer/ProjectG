--[[
	PetSavedPopup (stage client)

	기능/구조는 lobby의 RewardPopup과 동일(Container.Rewards 템플릿 풀 + BackgroundButton 닫기 +
	PopupManager 스택 관리)하되, 보상(재화) 대신 획득한 펫을 보여준다.

	GUI 트리: PopupScreenGui.Content.PetSavedPopup (CanvasGroup)
		BackgroundButton — 클릭 시 닫기
		Container.Rewards (Frame, UIListLayout)
			Reward (Frame) — 펫 1마리 단위 템플릿. PetIcon(ImageLabel), PetName(TextLabel) 외
			LightEffect/SparkleEffect_1~3는 디자인 이펙트라 손대지 않음.
		Container.RibbonRoot.Ribbon_Reward
		TouchToContinue

	트리거: 서버(PetManager)가 한 번의 공격 판정(펀치/트램플) 안에서 동기적으로 지급한 펫들을
	task.defer로 모아 PetSavedEvent를 FireClient(player, petIds: {string})로 배열째 보낸다.
	여기서 그걸 받아 enqueue()에 쌓는다(PetSavedPopup.init()).

	한 팝업에는 최대 MAX_REWARDS_PER_POPUP(4)마리만 보여준다. 한 번에 그보다 많이 들어오면
	나머지는 pendingQueue에 남아 있다가, 지금 팝업이 닫힐 때(자동 닫힘이든 클릭이든) 그 다음
	배치를 이어서 연다 — enqueue/openNextBatch 참고.

	PetIcon: ReplicatedStorage.DataTable.PetData(서버 PetData가 DataManager.init()에서 복제)의
	pets[petId].iconAssetId를 그대로 Image에 대입.
	PetName: StringData에서 key=petId(예: "Pet_01")로 조회한 kr 텍스트(StringHelper.get).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)
local SoundManager = require(Shared.Managers.SoundManager)
local StringHelper = require(Shared.Helpers.StringHelper)
local StringBinder = require(Shared.Helpers.StringBinder)
local StageEndState = require(script.Parent.Parent.StageEndState)

local PetSavedPopup = {}

local POPUP_ROOT_NAME = "PetSavedPopup"
local REWARDS_FRAME_NAME = "Rewards"
local REWARD_SLOT_NAME = "Reward"
local LOCALE = "kr"
local AUTO_CLOSE_DELAY_SEC = 2 -- 노출 후 이 시간이 지나면 자동으로 닫힘
local MAX_REWARDS_PER_POPUP = 4 -- 한 팝업에 동시에 보여줄 최대 펫 수. 초과분은 pendingQueue에서 다음 팝업으로

local initialized = false
local activeSession: { close: () -> () }? = nil
local petDataCache: any? = nil
local closeGeneration = 0

--- 아직 화면에 못 보여준 petId들. enqueue()로 쌓이고, openNextBatch()가 앞에서부터
--- MAX_REWARDS_PER_POPUP개씩 꺼내 새 팝업으로 연다.
local pendingQueue: { string } = {}

local petSlotTemplate: Frame? = nil
local petSlotClones: { Frame } = {}

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

local function getPetSavedPopupRoot(): GuiObject?
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

local function getPetData(): any?
	if petDataCache then
		return petDataCache
	end
	local ok, result = pcall(function()
		return require(ReplicatedStorage:WaitForChild("DataTable"):WaitForChild("PetData"))
	end)
	if ok then
		petDataCache = result
	else
		warn("[PetSavedPopup] PetData 로드 실패:", result)
	end
	return petDataCache
end

local function resolvePetIconAssetId(petId: string): string?
	local raw = getPetData()
	local pets = if typeof(raw) == "table" then (raw :: any).pets else nil
	if typeof(pets) ~= "table" then
		return nil
	end
	local def = pets[petId]
	if typeof(def) ~= "table" or typeof(def.iconAssetId) ~= "string" then
		return nil
	end
	return def.iconAssetId
end

local function ensurePetSlotTemplate(container: Instance): boolean
	if petSlotTemplate then
		return true
	end

	local rewardsFrameInst = container:FindFirstChild(REWARDS_FRAME_NAME)
	if not (rewardsFrameInst and rewardsFrameInst:IsA("GuiObject")) then
		warn("[PetSavedPopup] Container.Rewards 없음")
		return false
	end

	local templateInst = rewardsFrameInst:FindFirstChild(REWARD_SLOT_NAME)
	if not (templateInst and templateInst:IsA("GuiObject")) then
		warn("[PetSavedPopup] Container.Rewards.Reward 없음")
		return false
	end

	local template = templateInst :: Frame
	template.Visible = false
	template.LayoutOrder = 0
	petSlotTemplate = template
	return true
end

local function getPetSlot(index: number): Frame?
	local template = petSlotTemplate
	if not template then
		return nil
	end

	if index == 1 then
		return template
	end

	local cloneIndex = index - 1
	while #petSlotClones < cloneIndex do
		local clone = template:Clone()
		clone.Name = REWARD_SLOT_NAME .. tostring(#petSlotClones + 2)
		clone.Parent = template.Parent
		table.insert(petSlotClones, clone)
	end

	return petSlotClones[cloneIndex]
end

local function hideAllPetSlots()
	if petSlotTemplate then
		petSlotTemplate.Visible = false
	end
	for _, clone in petSlotClones do
		clone.Visible = false
	end
end

local function applyPetSlot(slot: Frame, petId: string): boolean
	local petIconInst = slot:FindFirstChild("PetIcon")
	local petNameInst = slot:FindFirstChild("PetName")
	if not (petIconInst and petIconInst:IsA("ImageLabel")) then
		warn("[PetSavedPopup]", slot.Name, "PetIcon (ImageLabel) 없음")
		return false
	end
	if not (petNameInst and petNameInst:IsA("TextLabel")) then
		warn("[PetSavedPopup]", slot.Name, "PetName (TextLabel) 없음")
		return false
	end

	local iconAssetId = resolvePetIconAssetId(petId)
	if not iconAssetId then
		warn("[PetSavedPopup] PetData에 iconAssetId 없음:", petId)
		return false
	end

	(petIconInst :: ImageLabel).Image = iconAssetId
	local petName = petNameInst :: TextLabel
	petName.Text = StringHelper.get(petId, LOCALE)
	return true
end

--- task.delay는 취소할 수 없으므로, "세대" 번호로 오래된 예약을 무효화하는 방식으로 타이머를
--- 리셋한다. 이미 열려 있는 팝업에 새 펫이 들어와 체류시간을 다시 2초로 늘릴 때 사용.
local function scheduleAutoClose(closeFn: () -> ())
	closeGeneration += 1
	local myGeneration = closeGeneration
	task.delay(AUTO_CLOSE_DELAY_SEC, function()
		if myGeneration == closeGeneration then
			closeFn()
		end
	end)
end

local function applyPetSlots(rootGui: GuiObject, petIds: { string }): boolean
	local container = rootGui:FindFirstChild("Container")
	if not container then
		warn("[PetSavedPopup] Container 없음")
		return false
	end
	if not ensurePetSlotTemplate(container) then
		return false
	end

	hideAllPetSlots()

	for index, petId in ipairs(petIds) do
		local slot = getPetSlot(index)
		if not slot then
			warn("[PetSavedPopup] 슬롯 확보 실패:", index)
			return false
		end
		slot.LayoutOrder = index
		slot.Visible = true
		if not applyPetSlot(slot, petId) then
			return false
		end
	end

	return true
end

function PetSavedPopup.open(petIds: { string }, onClose: (() -> ())?)
	local function finishOnClose()
		if onClose then
			onClose()
		end
	end

	-- 스테이지가 이미 클리어/오버로 끝났으면 열지 않는다. 보스 처치 시 StageClearedEvent
	-- 직후(같은 프레임) PetSavedEvent가 뒤따라올 수 있는데, GameClearPopup/GameOverPopup의
	-- 연출이 여러 프레임 yield되는 동안 이 이벤트가 뒤늦게 처리되면 결과 팝업 위에 겹쳐
	-- 뜨는 문제가 있었다(closeOthers=true는 "나보다 먼저 열린 팝업 닫기"만 처리하고 반대
	-- 방향은 못 막음).
	if StageEndState.isEnded() then
		finishOnClose()
		return
	end

	if typeof(petIds) ~= "table" or #petIds == 0 then
		warn("[PetSavedPopup] 잘못된 인자:", petIds)
		finishOnClose()
		return
	end

	-- 이미 열려 있으면 닫았다 다시 여는(pushPopup/popPopup을 반복 호출하는) 대신, 지금 팝업은
	-- 그대로 두고 새로 들어온 petId는 pendingQueue에 밀어넣는다 — 지금 팝업이 닫힐 때
	-- openNextBatch()가 이어서 보여준다. (보통 이 경로로는 안 들어온다: enqueue()가 activeSession이
	-- 없을 때만 open()을 호출하므로. 그래도 open()이 직접 호출될 가능성에 대비한 방어 코드.)
	if activeSession then
		for _, petId in petIds do
			table.insert(pendingQueue, petId)
		end
		return
	end

	local rootGui = getPetSavedPopupRoot()
	if not rootGui then
		warn("[PetSavedPopup] Content.PetSavedPopup 없음")
		finishOnClose()
		return
	end
	StringBinder.applySubtreeOnce(rootGui)

	local bgBtnInst = rootGui:FindFirstChild("BackgroundButton")
	if not (bgBtnInst and bgBtnInst:IsA("GuiButton")) then
		warn("[PetSavedPopup] BackgroundButton 없음")
		finishOnClose()
		return
	end
	local backgroundBtn = bgBtnInst :: GuiButton

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[PetSavedPopup] Content 없음")
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
		hideAllPetSlots()
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
	if not applyPetSlots(rootGui, petIds) then
		close()
		return
	end

	SoundManager.playSfx(SoundManager.Sfx.RewardReveal)

	prepareClickableButton(backgroundBtn)
	table.insert(connections, backgroundBtn.Activated:Connect(close))

	scheduleAutoClose(close)

	activeSession = { close = close }
end

function PetSavedPopup.close()
	if activeSession then
		activeSession.close()
	end
end

--- pendingQueue 맨 앞에서 최대 MAX_REWARDS_PER_POPUP개를 꺼내 새 팝업을 연다. 지금 팝업이 이미 열려
--- 있으면(activeSession) 아무것도 하지 않는다 — 그 팝업이 닫힐 때 onClose로 다시 호출된다.
local function openNextBatch()
	if activeSession or #pendingQueue == 0 then
		return
	end

	local batch: { string } = {}
	for _ = 1, math.min(MAX_REWARDS_PER_POPUP, #pendingQueue) do
		local petId = table.remove(pendingQueue, 1)
		if petId then
			table.insert(batch, petId)
		end
	end

	PetSavedPopup.open(batch, openNextBatch)
end

--- PetSavedEvent로 들어온 petId들을 pendingQueue에 쌓고, 지금 아무 팝업도 안 떠 있으면 즉시 연다.
--- 5마리 이상 한 번에 들어와도 여기서는 그냥 다 쌓아두기만 하고, 실제 노출은 openNextBatch가
--- MAX_REWARDS_PER_POPUP(4)개씩 끊어서 순차적으로 담당한다.
function PetSavedPopup.enqueue(petIds: { string })
	if typeof(petIds) ~= "table" or #petIds == 0 then
		return
	end
	for _, petId in petIds do
		table.insert(pendingQueue, petId)
	end
	openNextBatch()
end

function PetSavedPopup.init()
	if initialized then
		return
	end
	initialized = true

	local rootGui = getPetSavedPopupRoot()
	if rootGui then
		local container = rootGui:FindFirstChild("Container")
		if container then
			ensurePetSlotTemplate(container)
			hideAllPetSlots()
		end
	end

	ReplicatedStorage:WaitForChild("PetSavedEvent").OnClientEvent:Connect(function(petIds: any)
		if typeof(petIds) ~= "table" then
			return
		end
		local validated: { string } = {}
		for _, petId in petIds do
			if typeof(petId) == "string" then
				table.insert(validated, petId)
			end
		end
		PetSavedPopup.enqueue(validated)
	end)

	print("[PetSavedPopup] 초기화 완료")
end

return PetSavedPopup
