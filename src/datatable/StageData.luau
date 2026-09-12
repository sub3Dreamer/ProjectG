--[[
	Rojo: src/datatable/StageData.luau → ServerStorage.DataTable.StageData

	stages 테이블 키 = stageNumber (number).
	  nameKey      : string — StringData 키 (Stage_{N}_Name)
	  timeLimitSec : number — 스테이지 제한시간(초) (구 StageConfig.TimeLimit)

	clearRewardByDifficulty 테이블 키 = difficulty (1=Easy/2=Normal/3=Hard, DifficultyConfig 참고).
	  스테이지 번호와 무관하게 전 스테이지 공통 — 난이도가 높을수록 보상 증가.
]]

return {
	stages = {
		[1] = { nameKey = "Stage_01_Name", timeLimitSec = 300, mapImageAssetId = "rbxassetid://100017672581056" }, -- 스테이지 1 - 파리
		[2] = { nameKey = "Stage_02_Name", timeLimitSec = 300, mapImageAssetId = "rbxassetid://100017672581056" }, -- 스테이지 2 - 서울
		[3] = { nameKey = "Stage_03_Name", timeLimitSec = 300, mapImageAssetId = "rbxassetid://100017672581056" }, -- 스테이지 3 - 도쿄
	},

	clearRewardByDifficulty = {
		[1] = { -- Easy
			{ currencyType = "Gold", amount = 200 },
			{ currencyType = "BattlePassPoint", amount = 20 },
		},
		[2] = { -- Normal
			{ currencyType = "Gold", amount = 300 },
			{ currencyType = "BattlePassPoint", amount = 30 },
		},
		[3] = { -- Hard
			{ currencyType = "Gold", amount = 400 },
			{ currencyType = "BattlePassPoint", amount = 40 },
		},
	},
}
