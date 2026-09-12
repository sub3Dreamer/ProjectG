--[[
	ItemInventoryHUD (stage client)

	GameScreenGui.ItemInventory.{FeverGaugeUp,FeverGaugeMax}.Btn 클릭 시
	UseItemRequestEvent:FireServer(itemType) 호출 — 서버가 보유 수량 확인 후 소모 + 효과 적용.

	ItemCnt는 최초 GetInventorySnapshot(RemoteFunction)으로 채우고, 클릭 시 클라이언트에서
	1 차감(낙관적 갱신) — 서버가 최종 권한을 가지므로 표시용 카운트일 뿐 별도 동기화 이벤트는 두지 않음.
	보유 수량이 0이면 클릭해도 서버 호출 자체를 생략(무반응).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local InventoryHelper = require(Shared.Helpers.InventoryHelper)

local ItemInventoryHUD = {}

local ITEM_SLOT_NAMES = { "FeverGaugeUp", "FeverGaugeMax" }

local initialized = false

local function fetchInitialCounts(): { [string]: number }
	local counts: { [string]: number } = {}
	local remote = ReplicatedStorage:FindFirstChild(InventoryHelper.GET_SNAPSHOT_REMOTE_NAME)
	if not (remote and remote:IsA("RemoteFunction")) then
		warn("[ItemInventoryHUD]", InventoryHelper.GET_SNAPSHOT_REMOTE_NAME, "(RemoteFunction) 없음")
		return counts
	end

	local ok, snapshot = pcall(function()
		return (remote :: RemoteFunction):InvokeServer()
	end)
	if not ok or typeof(snapshot) ~= "table" or typeof(snapshot.items) ~= "table" then
		return counts
	end

	for _, entry in snapshot.items do
		if typeof(entry) == "table" and typeof(entry.itemType) == "string" and typeof(entry.count) == "number" then
			counts[entry.itemType] = entry.count
		end
	end
	return counts
end

local function bindItemSlot(
	itemInventory: Instance,
	itemType: string,
	useItemRequestEvent: RemoteEvent,
	initialCounts: { [string]: number }
)
	local slot = itemInventory:FindFirstChild(itemType)
	if not slot then
		warn("[ItemInventoryHUD] ItemInventory.", itemType, "없음")
		return
	end

	local btnInst = slot:FindFirstChild("Btn")
	if not (btnInst and btnInst:IsA("GuiButton")) then
		warn("[ItemInventoryHUD]", itemType, ".Btn (GuiButton) 없음")
		return
	end
	local btn = btnInst :: GuiButton

	local cntInst = slot:FindFirstChild("ItemCnt")
	local cntLabel: TextLabel? = if cntInst and cntInst:IsA("TextLabel") then cntInst :: TextLabel else nil
	if not cntLabel then
		warn("[ItemInventoryHUD]", itemType, ".ItemCnt (TextLabel) 없음")
	end

	local count = initialCounts[itemType] or 0

	local function refreshCntLabel()
		if cntLabel then
			cntLabel.Text = tostring(count)
		end
	end

	refreshCntLabel()

	btn.Activated:Connect(function()
		if count <= 0 then
			return
		end
		count -= 1
		refreshCntLabel()
		useItemRequestEvent:FireServer(itemType)
	end)
end

function ItemInventoryHUD.init()
	if initialized then
		return
	end
	initialized = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local gameGui = playerGui:WaitForChild("GameScreenGui")
	local itemInventory = gameGui:FindFirstChild("ItemInventory")
	if not itemInventory then
		warn("[ItemInventoryHUD] GameScreenGui.ItemInventory 없음")
		return
	end

	local useItemRequestEvent = ReplicatedStorage:WaitForChild("UseItemRequestEvent") :: RemoteEvent
	local initialCounts = fetchInitialCounts()

	for _, itemType in ITEM_SLOT_NAMES do
		bindItemSlot(itemInventory, itemType, useItemRequestEvent, initialCounts)
	end

	print("[ItemInventoryHUD] 초기화 완료")
end

return ItemInventoryHUD
