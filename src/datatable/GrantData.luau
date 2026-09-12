--[[
	Rojo: src/datatable/GrantData.luau → ServerStorage.DataTable.GrantData

	접속 유저 1회성 지급(캠페인) 정의.
	유저 SavedPlayerData.GrantedCampaigns[id] 로 중복 지급 방지.

	필드:
	  id      : string  — 캠페인 식별자 (바꾸면 새 1회 지급으로 취급)
	  enabled : boolean — false면 이후 접속 유저에게 미지급 (이미 받은 유저 회수 없음)
	  items   : { { itemType: ItemType, itemAmount: number } } — 지급 목록
]]

return {
	campaigns = {
		{
			id = "TestStarterItems_v1",
			enabled = true,
			items = {
				{ itemType = "SpeedUp", itemAmount = 5 },
				{ itemType = "FeverGaugeUp", itemAmount = 5 },
				{ itemType = "FeverGaugeMax", itemAmount = 5 },
				{ itemType = "RelicNormalKey", itemAmount = 5 },
				{ itemType = "RelicSpecialKey", itemAmount = 5 },
			},
		},
	},
}
