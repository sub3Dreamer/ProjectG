--[[
	Rojo: src/datatable/PetData.luau → ServerStorage.DataTable.PetData

	스테이지 펫 배치용 마스터 데이터.
	키: pet id
	필드:
	  id        : string — pet 식별자
	  modelName : string — 배치할 모델 이름
]]

return {
	pets = {
		["Pet_01"] = { id = "Pet_01", modelName = "Golden Piggy Bank", iconAssetId = "rbxassetid://102527850086594" },
		["Pet_02"] = { id = "Pet_02", modelName = "White Rabbit", iconAssetId = "rbxassetid://120274826805857" },
		["Pet_03"] = { id = "Pet_03", modelName = "Cat", iconAssetId = "rbxassetid://75720940050696" },
		["Pet_04"] = { id = "Pet_04", modelName = "Doge", iconAssetId = "rbxassetid://121906896511089" },
		["Pet_05"] = { id = "Pet_05", modelName = "Brown Chihuahua", iconAssetId = "rbxassetid://72260598063485" },
		["Pet_06"] = { id = "Pet_06", modelName = "Axolotl", iconAssetId = "rbxassetid://131359749962233" },
		["Pet_07"] = { id = "Pet_07", modelName = "Ghost Dragon", iconAssetId = "rbxassetid://129022168419445" },
		-- ["Pet_08"] = { id = "Pet_08", modelName = "Mystic Flower", iconAssetId = "rbxassetid://78723485593799" },
		-- ["Pet_09"] = { id = "Pet_09", modelName = "Nerdy Dragon", iconAssetId = "rbxassetid://133153050542533" },
		["Pet_10"] = { id = "Pet_10", modelName = "Parrot", iconAssetId = "rbxassetid://84722808518088" },
	},
}
