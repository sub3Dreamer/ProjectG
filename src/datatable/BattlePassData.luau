--[[
	Rojo: src/datatable/BattlePassData.luau → ServerStorage.DataTable.BattlePassData

	seasonStartTime / seasonEndTime : UTC DateString ("YYYY-MM-DD")
	런타임 비교: TimeHelper.dateStringToUnix / dateStringToDayEndUnix

	레벨 0 = 시작, 최대 30.
	xpRequired[level] = (level-1) → level 구간에 필요한 XP

	maxLevelPremiumReward: 최대 레벨 + 프리미엄 패스 보유 시 수령 (사이드 패널)
	premiumGamePassId: Roblox Creator Dashboard 프리미엄 패스 GamePass ID
	jumpLevelProductId: BattlePassPopup BtnJumpLevel용 Developer Product ID (구매 시 레벨 +5, xp 0 초기화)
]]

return {
	seasonIndex = 1,
	seasonStartTime = "2026-07-06",
	seasonEndTime = "2026-08-10",
	premiumGamePassId = 1898334892,
	jumpLevelProductId = 3609553930,

	startLevel = 0,
	maxLevel = 30,

	maxLevelPremiumReward = {
		rewardType = "Costume",
		id = "Costume_03",
	},

	levels = {
		[1] = {
			level = 1,
			xpRequired = 100,
			freeReward = { rewardType = "Currency", currencyType = "Gem", amount = 50 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[2] = {
			level = 2,
			xpRequired = 110,
			freeReward = { rewardType = "Item", itemType = "FeverGaugeMax", amount = 1 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[3] = {
			level = 3,
			xpRequired = 120,
			freeReward = { rewardType = "Currency", currencyType = "Gem", amount = 50 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[4] = {
			level = 4,
			xpRequired = 130,
			freeReward = { rewardType = "Item", itemType = "FeverGaugeUp", amount = 1 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[5] = {
			level = 5,
			xpRequired = 140,
			freeReward = { rewardType = "Currency", currencyType = "Gem", amount = 50 },
			premiumReward = { rewardType = "Item", itemType = "RelicSpecialKey", amount = 1 },
		},
		[6] = {
			level = 6,
			xpRequired = 150,
			freeReward = { rewardType = "Item", itemType = "RelicNormalKey", amount = 1 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[7] = {
			level = 7,
			xpRequired = 160,
			freeReward = { rewardType = "Currency", currencyType = "Gem", amount = 50 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[8] = {
			level = 8,
			xpRequired = 170,
			freeReward = { rewardType = "Item", itemType = "FeverGaugeUp", amount = 1 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[9] = {
			level = 9,
			xpRequired = 180,
			freeReward = { rewardType = "Currency", currencyType = "Gem", amount = 50 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[10] = {
			level = 10,
			xpRequired = 190,
			freeReward = { rewardType = "Item", itemType = "FeverGaugeMax", amount = 1 },
			premiumReward = { rewardType = "Item", itemType = "RelicSpecialKey", amount = 1 },
		},
		[11] = {
			level = 11,
			xpRequired = 200,
			freeReward = { rewardType = "Currency", currencyType = "Gem", amount = 50 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[12] = {
			level = 12,
			xpRequired = 210,
			freeReward = { rewardType = "Item", itemType = "RelicNormalKey", amount = 1 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[13] = {
			level = 13,
			xpRequired = 220,
			freeReward = { rewardType = "Currency", currencyType = "Gem", amount = 50 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[14] = {
			level = 14,
			xpRequired = 230,
			freeReward = { rewardType = "Item", itemType = "FeverGaugeMax", amount = 1 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[15] = {
			level = 15,
			xpRequired = 240,
			freeReward = { rewardType = "Currency", currencyType = "Gem", amount = 50 },
			premiumReward = { rewardType = "Item", itemType = "RelicSpecialKey", amount = 1 },
		},
		[16] = {
			level = 16,
			xpRequired = 250,
			freeReward = { rewardType = "Item", itemType = "RelicNormalKey", amount = 1 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[17] = {
			level = 17,
			xpRequired = 260,
			freeReward = { rewardType = "Currency", currencyType = "Gem", amount = 50 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[18] = {
			level = 18,
			xpRequired = 270,
			freeReward = { rewardType = "Item", itemType = "FeverGaugeUp", amount = 1 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[19] = {
			level = 19,
			xpRequired = 280,
			freeReward = { rewardType = "Currency", currencyType = "Gem", amount = 50 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[20] = {
			level = 20,
			xpRequired = 290,
			freeReward = { rewardType = "Item", itemType = "RelicNormalKey", amount = 1 },
			premiumReward = { rewardType = "Item", itemType = "RelicSpecialKey", amount = 1 },
		},
		[21] = {
			level = 21,
			xpRequired = 300,
			freeReward = { rewardType = "Currency", currencyType = "Gem", amount = 50 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[22] = {
			level = 22,
			xpRequired = 310,
			freeReward = { rewardType = "Item", itemType = "FeverGaugeUp", amount = 1 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[23] = {
			level = 23,
			xpRequired = 320,
			freeReward = { rewardType = "Currency", currencyType = "Gem", amount = 50 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[24] = {
			level = 24,
			xpRequired = 330,
			freeReward = { rewardType = "Item", itemType = "FeverGaugeMax", amount = 1 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[25] = {
			level = 25,
			xpRequired = 340,
			freeReward = { rewardType = "Currency", currencyType = "Gem", amount = 50 },
			premiumReward = { rewardType = "Item", itemType = "RelicSpecialKey", amount = 1 },
		},
		[26] = {
			level = 26,
			xpRequired = 350,
			freeReward = { rewardType = "Item", itemType = "RelicNormalKey", amount = 1 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[27] = {
			level = 27,
			xpRequired = 360,
			freeReward = { rewardType = "Currency", currencyType = "Gem", amount = 50 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[28] = {
			level = 28,
			xpRequired = 370,
			freeReward = { rewardType = "Item", itemType = "FeverGaugeMax", amount = 1 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[29] = {
			level = 29,
			xpRequired = 380,
			freeReward = { rewardType = "Currency", currencyType = "Gem", amount = 50 },
			premiumReward = { rewardType = "Currency", currencyType = "Gem", amount = 100 },
		},
		[30] = {
			level = 30,
			xpRequired = 390,
			freeReward = { rewardType = "Item", itemType = "FeverGaugeUp", amount = 1 },
			premiumReward = { rewardType = "Item", itemType = "RelicSpecialKey", amount = 1 },
		},
	},
}
