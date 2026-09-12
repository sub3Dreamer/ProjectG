--[[
	ToastHUD (stage client)

	펫 획득 시 PetSavedPopup(모달 팝업) 대신 노출하는 토스트. ToastPopup_1~3 각 슬롯은
	자기 자신만의 독립적인 등장(Scale 0→1, 0.5s)→정지(2s)→퇴장(Scale 1→0, 0.5s) 사이클을
	돈다. 콘텐츠가 슬롯 사이를 이동하지는 않는다 — 대신 새 펫이 등장할 때마다 그 슬롯을
	Toast.UIListLayout 상에서 최상위(LayoutOrder = 2)로 끌어올리고, 그 순간 노출 중이던
	다른 슬롯들은 LayoutOrder를 1씩 낮춰 밀어낸다(promoteSlot). UIListLayout은 이 값 변화를
	즉시 반영(스냅)하며, 별도의 이동 트윈은 넣지 않는다.

	GUI 트리: GameScreenGui.Toast.ToastPopup_1~3 (LayoutOrder 대상)
		Container (Frame) — Visible/Position.X.Scale로 등장·퇴장 연출
			Pet.PetIcon (ImageLabel), PetName (TextLabel) — PetSavedPopup과 동일한 방식(PetData
			iconAssetId / StringHelper.get(petId, "kr"))으로 세팅.

	슬롯 배정(pickTargetSlot): 비어 있는(busy=false) 슬롯이 있으면 1→2→3 순서로 채운다(램프업).
	3개가 모두 노출 중이면 대기하지 않고, 그 순간 LayoutOrder == 0인(가장 아래로 밀려난) 슬롯을
	즉시 재활용한다 — 진행 중이던 사이클은 슬롯별 generation 카운터로 무효화되고, 새 펫 내용으로
	처음부터 다시 전체 사이클을 재생한다.

	트리거: 서버(PetManager)가 PetSavedEvent로 FireClient(player, petIds: {string}) 보내는 걸
	그대로 받아 각 petId를 enqueue한다(펫 1마리 = 토스트 1장).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StringHelper = require(Shared.Helpers.StringHelper)
local StringBinder = require(Shared.Helpers.StringBinder)
local StageEndState = require(script.Parent.StageEndState)
local SoundManager = require(Shared.Managers.SoundManager)

local ToastHUD = {}

local TOAST_ROOT_NAME = "Toast"
local SLOT_NAMES = { "ToastPopup_1", "ToastPopup_2", "ToastPopup_3" }
local LOCALE = "kr"
local HOLD_SEC = 2
local TWEEN_IN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_OUT_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

type Slot = {
	popupInst: GuiObject,
	container: GuiObject,
	petIcon: ImageLabel,
	petName: TextLabel,
	shownPosition: UDim2,
	hiddenPosition: UDim2,
	busy: boolean,
	activeTween: Tween?,
}

local SLOT_COUNT = 3
local BASE_LAYOUT_ORDERS = { 2, 1, 0 }
local TOP_LAYOUT_ORDER = SLOT_COUNT - 1

local initialized = false
local petDataCache: any? = nil
local slots: { Slot } = {}

--- 슬롯에 새 내용이 배정될 때마다 +1. 진행 중인 정지/퇴장 코루틴이 자기 세대가 최신인지
--- 확인해, 가로채기(재활용)로 무효화된 오래된 코루틴을 조용히 종료시키는 데 쓴다.
local generation: { number } = {}

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
		warn("[ToastHUD] PetData 로드 실패:", result)
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

local function getToastRoot(): Instance?
	local player = Players.LocalPlayer
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return nil
	end
	local gameGui = playerGui:FindFirstChild("GameScreenGui")
	if not gameGui then
		return nil
	end
	return gameGui:FindFirstChild(TOAST_ROOT_NAME)
end

local function buildSlot(popupInst: Instance): Slot?
	if not popupInst:IsA("GuiObject") then
		warn("[ToastHUD]", popupInst.Name, "(GuiObject) 아님 — LayoutOrder 설정 불가")
		return nil
	end

	local containerInst = popupInst:FindFirstChild("Container")
	if not (containerInst and containerInst:IsA("GuiObject")) then
		warn("[ToastHUD]", popupInst.Name, ".Container (GuiObject) 없음")
		return nil
	end
	local container = containerInst :: GuiObject

	local petInst = container:FindFirstChild("Pet")
	local petIconInst = petInst and petInst:FindFirstChild("PetIcon")
	if not (petIconInst and petIconInst:IsA("ImageLabel")) then
		warn("[ToastHUD]", popupInst.Name, ".Container.Pet.PetIcon (ImageLabel) 없음")
		return nil
	end

	local petNameInst = container:FindFirstChild("PetName")
	if not (petNameInst and petNameInst:IsA("TextLabel")) then
		warn("[ToastHUD]", popupInst.Name, ".Container.PetName (TextLabel) 없음")
		return nil
	end

	local shownPosition = container.Position
	local hiddenPosition = UDim2.new(0, shownPosition.X.Offset, shownPosition.Y.Scale, shownPosition.Y.Offset)

	container.Visible = false
	container.Position = hiddenPosition

	return {
		popupInst = popupInst :: GuiObject,
		container = container,
		petIcon = petIconInst :: ImageLabel,
		petName = petNameInst :: TextLabel,
		shownPosition = shownPosition,
		hiddenPosition = hiddenPosition,
		busy = false,
		activeTween = nil,
	}
end

local function applySlotContent(slot: Slot, petId: string): boolean
	local iconAssetId = resolvePetIconAssetId(petId)
	if not iconAssetId then
		warn("[ToastHUD] PetData에 iconAssetId 없음:", petId)
		return false
	end
	slot.petIcon.Image = iconAssetId
	slot.petName.Text = StringHelper.get(petId, LOCALE)
	return true
end

--- target을 제외한 나머지 슬롯 전부(노출 중이든 idle이든)의 LayoutOrder를 1씩 낮춰
--- 밀어내고, target은 최상위(TOP_LAYOUT_ORDER)로 끌어올린다.
--- idle 슬롯도 반드시 같이 밀어야 한다 — idle 슬롯은 자기가 마지막으로 노출됐을 때의
--- LayoutOrder를 그대로 들고 있으므로, busy인 슬롯만 밀면 그 값이 새로 promote되는
--- 슬롯의 값(TOP_LAYOUT_ORDER)과 겹치면서(중복) 원래 그 값이 차지하던 자리는 비어버려
--- 셋 사이의 순서가 어긋난다.
local function promoteSlot(target: Slot)
	for _, other in slots do
		if other ~= target then
			other.popupInst.LayoutOrder -= 1
		end
	end
	target.popupInst.LayoutOrder = TOP_LAYOUT_ORDER
end

--- 비어 있는 슬롯이 있으면 1→2→3 순서로 채운다(램프업). 3개가 다 노출 중이면 대기하지
--- 않고 그 순간 LayoutOrder == 0인(가장 아래로 밀려난) 슬롯을 즉시 재활용 대상으로 고른다.
local function pickTargetSlot(): (Slot?, number?)
	for index, slot in slots do
		if not slot.busy then
			return slot, index
		end
	end
	for index, slot in slots do
		if slot.popupInst.LayoutOrder == 0 then
			return slot, index
		end
	end
	return nil, nil
end

--- 슬롯에 petId를 배정하고 등장→정지→퇴장 사이클을 처음부터 재생한다. 이미 다른 사이클이
--- 진행 중이던 슬롯을 가로챈 경우, 그 이전 사이클은 generation 불일치로 조용히 중단된다.
local function assignSlot(slot: Slot, index: number, petId: string)
	generation[index] += 1
	local myGen = generation[index]

	-- 노출 중인 슬롯을 가로챈 경우, 그 슬롯에서 아직 재생 중이던 트윈(등장/퇴장)이 새
	-- 트윈과 동시에 Position을 건드리며 한두 프레임 튀는 걸 막기 위해 먼저 정리한다.
	if slot.activeTween then
		slot.activeTween:Cancel()
		slot.activeTween = nil
	end

	slot.busy = true
	promoteSlot(slot)

	if not applySlotContent(slot, petId) then
		slot.busy = false
		return
	end

	slot.container.Position = slot.hiddenPosition
	slot.container.Visible = true

	SoundManager.playSfx(SoundManager.Sfx.RewardReveal)

	local tweenIn = TweenService:Create(slot.container, TWEEN_IN_INFO, { Position = slot.shownPosition })
	slot.activeTween = tweenIn
	tweenIn:Play()
	tweenIn.Completed:Wait()
	if slot.activeTween == tweenIn then
		slot.activeTween = nil
	end
	if generation[index] ~= myGen then
		return
	end

	task.wait(HOLD_SEC)
	if generation[index] ~= myGen then
		return
	end

	local tweenOut = TweenService:Create(slot.container, TWEEN_OUT_INFO, { Position = slot.hiddenPosition })
	slot.activeTween = tweenOut
	tweenOut:Play()
	tweenOut.Completed:Wait()
	if slot.activeTween == tweenOut then
		slot.activeTween = nil
	end
	if generation[index] ~= myGen then
		return
	end

	slot.container.Visible = false
	if generation[index] == myGen then
		slot.busy = false
	end
end

--- petId 하나를 노출시킨다: 빈 슬롯이 있으면 거기에, 없으면 가장 아래로 밀려난 슬롯을
--- 즉시 재활용한다.
function ToastHUD.enqueue(petId: string)
	if typeof(petId) ~= "string" or petId == "" then
		return
	end
	-- GameClearPopup/GameOverPopup이 뜨는 도중 뒤늦게 도착한 PetSavedEvent가 그 위에 겹쳐
	-- 뜨지 않도록 한다. PetSavedPopup.open()과 동일한 이유(StageEndState 참고).
	if StageEndState.isEnded() then
		return
	end

	local slot, index = pickTargetSlot()
	if not slot or not index then
		warn("[ToastHUD] 배정 가능한 슬롯 없음")
		return
	end
	task.spawn(assignSlot, slot, index, petId)
end

--- 스튜디오 테스트용: PetData에 등록된 펫 중 하나를 무작위로 골라 토스트로 등장시킨다.
function ToastHUD.testEnqueueRandomPet()
	local raw = getPetData()
	local pets = if typeof(raw) == "table" then (raw :: any).pets else nil
	if typeof(pets) ~= "table" then
		return
	end

	local petIds: { string } = {}
	for petId in pets do
		table.insert(petIds, petId)
	end
	if #petIds == 0 then
		return
	end

	local petId = petIds[math.random(1, #petIds)]
	print("[ToastHUD] 테스트: 랜덤 펫 토스트 노출 ->", petId)
	ToastHUD.enqueue(petId)
end

function ToastHUD.init()
	if initialized then
		return
	end
	initialized = true

	local toastRoot = getToastRoot()
	if not toastRoot then
		warn("[ToastHUD] GameScreenGui.Toast 없음")
		return
	end

	for i, slotName in SLOT_NAMES do
		local popupInst = toastRoot:FindFirstChild(slotName)
		if not popupInst then
			warn("[ToastHUD] Toast.", slotName, " 없음")
			continue
		end
		StringBinder.applySubtreeOnce(popupInst)
		local slot = buildSlot(popupInst)
		if slot then
			slot.popupInst.LayoutOrder = BASE_LAYOUT_ORDERS[i]
			table.insert(slots, slot)
		end
	end

	for i = 1, SLOT_COUNT do
		generation[i] = 0
	end

	ReplicatedStorage:WaitForChild("PetSavedEvent").OnClientEvent:Connect(function(petIds: any)
		if typeof(petIds) ~= "table" then
			return
		end
		for _, petId in petIds do
			if typeof(petId) == "string" then
				ToastHUD.enqueue(petId)
			end
		end
	end)

	print("[ToastHUD] 초기화 완료")
end

return ToastHUD
