--[[
	Rojo: src/datatable/ShopData.luau → ServerStorage.DataTable.ShopData

	products 테이블 키(index)는 1 이상 정수.

	상품 필드:
	  index     : number  — 상품 인덱스
	  itemKey   : string  — ShopPopup GUI Item 이름 (예: Item_1)
	  productId : number  — Roblox Developer Product ID
	  rewards   : { { currencyType: string, amount: number } } 또는 { { rewardType: string, amount: number } } — 구매 보상 목록
	  hidden    : boolean? — true면 ShopPopup 그리드에 노출하지 않음(다른 팝업에서만 구매를 트리거하는 상품용)
]]

return {
	products = {
		[1] = {
			index = 1,
			itemKey = "Item_1",
			productId = 3607138562, -- Small Pile of Rubies
			rewards = {
				{ currencyType = "Gem", amount = 500 },
			},
		},
		[2] = {
			index = 2,
			itemKey = "Item_2",
			productId = 3607138717, -- Pouch of Rubies
			rewards = {
				{ currencyType = "Gem", amount = 1200 },
			},
		},
		[3] = {
			index = 3,
			itemKey = "Item_3",
			productId = 3607138820, -- Bag of Rubies
			rewards = {
				{ currencyType = "Gem", amount = 2500 },
			},
		},
		[4] = {
			index = 4,
			itemKey = "BattlePassJumpLevel",
			productId = 3609553930, -- BattlePassPopup BtnJumpLevel 전용 (레벨 +5)
			rewards = {
				{ rewardType = "BattlePassLevel", amount = 5 },
			},
			hidden = true,
		},
	},
}
