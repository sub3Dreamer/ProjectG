--[[
	Rojo: src/datatable/ItemData.luau → ServerStorage.DataTable.ItemData

	키: ItemType 명 (Types.ITEM_TYPES)
	필드:
	  type : ItemType 명
	  icon : string — UI 아이콘 키 (비어 있으면 미지정)
	  desc : string — StringData 키 ({ItemType}_Desc)
]]

return {
	items = {
		SpeedUp = {
			icon = "Stat_MoveSpeed_01",
			title = "SpeedUp_Title",
			desc = "SpeedUp_Desc",
		},
		FeverGaugeUp = {
			icon = "Consumable_Potion_02_Purple",
			title = "FeverGaugeUp_Title",
			desc = "FeverGaugeUp_Desc",
		},
		FeverGaugeMax = {
			icon = "Consumable_Potion_02_Red",
			title = "FeverGaugeMax_Title",
			desc = "FeverGaugeMax_Desc",
		},
		RelicNormalKey = {
			icon = "Economy_Key_02_Silver",
			title = "RelicNormalKey_Title",
			desc = "RelicNormalKey_Desc",
		},
		RelicSpecialKey = {
			icon = "Economy_Key_02_Gold",
			title = "RelicSpecialKey_Title",
			desc = "RelicSpecialKey_Desc",
		},
	},
}
