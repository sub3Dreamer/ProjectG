--[[
	Rojo: src/datatable/DailyRewardData.luau → ServerStorage.DataTable.DailyRewardData

	activeDatasetIndex 를 0 / 1 / 2 로 바꿔 이벤트 테이블 전환.
]]

return {
	activeDatasetIndex = 0,

	datasets = {
		[0] = {
			index = 0,
			name = "Default",
			rewards = {
				{ currencyType = "Gem", amount = 10 },
				{ currencyType = "Gem", amount = 20 },
				{ currencyType = "Gem", amount = 30 },
				{ currencyType = "Gem", amount = 40 },
				{ currencyType = "Gem", amount = 50 },
				{ currencyType = "Gem", amount = 60 },
				{ currencyType = "Gem", amount = 100 },
			},
		},
		[1] = {
			index = 1,
			name = "Event_Gem",
			rewards = {
				{ currencyType = "Gem", amount = 500 },
				{ currencyType = "Gem", amount = 750 },
				{ currencyType = "Gem", amount = 1000 },
				{ currencyType = "Gem", amount = 1250 },
				{ currencyType = "Gem", amount = 1500 },
				{ currencyType = "Gem", amount = 2000 },
				{ currencyType = "Gem", amount = 5000 },
			},
		},
		[2] = {
			index = 2,
			name = "Event_Gold",
			rewards = {
				{ currencyType = "Gold", amount = 1000 },
				{ currencyType = "Gold", amount = 2000 },
				{ currencyType = "Gold", amount = 3000 },
				{ currencyType = "Gold", amount = 4000 },
				{ currencyType = "Gold", amount = 5000 },
				{ currencyType = "Gold", amount = 7500 },
				{ currencyType = "Gold", amount = 20000 },
			},
		},
	},
}
