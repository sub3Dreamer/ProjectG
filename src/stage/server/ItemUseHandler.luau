--[[
	ItemUseHandler (stage server)

	클라이언트 UseItemRequestEvent(itemType) 수신 → 보유 수량 확인 후 1개 소모 + 효과 적용.
	보유 수량이 0(DataManager.consumeItem 실패)이면 무반응.

	FeverGaugeUp/FeverGaugeMax 효과값은 ItemData.luau에 수치 필드가 없고
	StringData.luau의 설명 텍스트(FeverGaugeUp_Desc: "50% 충전", FeverGaugeMax_Desc: "최대로 충전")로만
	존재하므로 여기 상수로 고정. FeverGaugeHandler.addPercent는 이미 Fever 모드 중엔 무시하는 가드가
	있으므로 FeverGaugeMax도 동일하게 addPercent(100)으로 처리(가드 재사용, 클램프로 인해 100%면 항상 최대).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DataManager = require(Shared.Managers.DataManager)
local Types = require(Shared.Types)

local FeverGaugeHandler = require(script.Parent.FeverGaugeHandler)

local ItemUseHandler = {}

local FEVER_GAUGE_UP_PERCENT = 50
local FEVER_GAUGE_MAX_PERCENT = 100

local ITEM_EFFECTS: { [Types.ItemType]: (Player) -> () } = {
	FeverGaugeUp = function(player: Player)
		FeverGaugeHandler.addPercent(player, FEVER_GAUGE_UP_PERCENT)
	end,
	FeverGaugeMax = function(player: Player)
		FeverGaugeHandler.addPercent(player, FEVER_GAUGE_MAX_PERCENT)
	end,
}

local function onUseItemRequest(player: Player, rawItemType: any)
	local itemType = Types.normalizeItemType(rawItemType)
	if not itemType then
		return
	end
	local effect = ITEM_EFFECTS[itemType]
	if not effect then
		return
	end
	if not DataManager.consumeItem(player, itemType, 1) then
		return
	end
	effect(player)
end

function ItemUseHandler.init(useItemRequestEvent: RemoteEvent)
	useItemRequestEvent.OnServerEvent:Connect(onUseItemRequest)
end

return ItemUseHandler
