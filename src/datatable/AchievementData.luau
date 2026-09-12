--[[
	Rojo: src/datatable/AchievementData.luau → ServerStorage.DataTable.AchievementData

	types — 업적 타입별 표시 마스터 (stringKey, icon, iconByCondition?)
	  iconByCondition — condition 값별 아이콘 (StageTimeClear, TargetStageClear 등)
	achievements — 업적 목록 (키 index = 1 이상 정수)

	업적 row 필드:
	  index       : number
	  type        : string  — types 테이블 키
	  condition   : string? — 2칸 포맷용 서브 변수 (불필요 시 "" 또는 생략)
	  progressCnt : number  — 포맷 2번째 값 + 타입별 목표/제한 (A안)
	  rewards     : { { currencyType, amount } }

	progressCnt 의미 (A안):
	  StageTimeClear     — m초 이내 (달성 goal=1)
	  TargetStageClear   — m회 클리어
	  StageClear 등     — progressCnt = 누적/횟수 목표
]]

return {
	types = {
		-- 스테이지 n회 클리어 (전체 합산)
		StageClear = {
			stringKey = "Achievement_StageClear",
			icon = "Stage",
		},
		-- 건물 n개 파괴
		PropDestroy = {
			stringKey = "Achievement_PropDestroy",
			icon = "Prop",
		},
		-- NPC n개 파괴
		NpcDestroy = {
			stringKey = "Achievement_NpcDestroy",
			icon = "Npc",
		},
		-- 특정 건물 n회 파괴 (condition = 건물 ID)
		TargetPropDestroy = {
			stringKey = "Achievement_TargetPropDestroy",
			icon = "Prop",
		},
		-- 피버 타임 n회 체험
		Fever = {
			stringKey = "Achievement_Fever",
			icon = "Fever",
		},
		-- 스테이지 n을 m초 이내 클리어 (condition = n, progressCnt = m초)
		StageTimeClear = {
			stringKey = "Achievement_StageTimeClear",
			icon = "Stage",
			iconByCondition = {
				["1"] = "Stage1",
			},
		},
		-- 일일 미션 n개 클리어
		MissionClear = {
			stringKey = "Achievement_MissionClear",
			icon = "Mission",
		},
		-- 골드 n만큼 획득
		GetGold = {
			stringKey = "Achievement_GetGold",
			icon = "Gold",
		},
		-- n명과 m회 플레이 (condition = n, progressCnt = m회)
		PartyPlay = {
			stringKey = "Achievement_PartyPlay",
			icon = "Party",
		},
		-- 스테이지 n을 m회 클리어 (condition = n, progressCnt = m회)
		TargetStageClear = {
			stringKey = "Achievement_TargetStageClear",
			icon = "Stage",
			iconByCondition = {
				["1"] = "Stage1",
			},
		},
		-- 게임 접속 n일
		Attendance = {
			stringKey = "Achievement_Attendance",
			icon = "Attendance",
		},
		-- 유물 뽑기 n회 진행
		RelicSummon = {
			stringKey = "Achievement_RelicSummon",
			icon = "Relic",
		},
		-- n등급 유물 m개 획득 (condition = 등급, progressCnt = m개)
		RelicGradeCollect = {
			stringKey = "Achievement_RelicGradeCollect",
			icon = "Relic",
		},
	},

	achievements = {
		[1] = {
			index = 1,
			type = "GetGold",
			condition = "",
			progressCnt = 10000,
			rewards = {
				{ currencyType = "Gem", amount = 50 },
				{ currencyType = "BattlePassPoint", amount = 10 },
			},
		},
		[2] = {
			index = 2,
			type = "GetGold",
			condition = "",
			progressCnt = 100000,
			rewards = {
				{ currencyType = "Gem", amount = 300 },
				{ currencyType = "BattlePassPoint", amount = 30 },
			},
		},
		[3] = {
			index = 3,
			type = "Attendance",
			condition = "",
			progressCnt = 10,
			rewards = {
				{ currencyType = "Gem", amount = 500 },
				{ currencyType = "BattlePassPoint", amount = 50 },
			},
		},
		[4] = {
			index = 4,
			type = "Attendance",
			condition = "",
			progressCnt = 30,
			rewards = {
				{ currencyType = "Gem", amount = 1000 },
				{ currencyType = "BattlePassPoint", amount = 100 },
			},
		},
		[5] = {
			index = 5,
			type = "StageTimeClear",
			condition = "1",
			progressCnt = 60,
			rewards = {
				{ currencyType = "Gem", amount = 100 },
				{ currencyType = "BattlePassPoint", amount = 20 },
			},
		},
		[6] = {
			index = 6,
			type = "TargetStageClear",
			condition = "1",
			progressCnt = 10,
			rewards = {
				{ currencyType = "Gem", amount = 200 },
				{ currencyType = "BattlePassPoint", amount = 40 },
			},
		},
		[7] = {
			index = 7,
			type = "Fever",
			condition = "",
			progressCnt = 100,
			rewards = {
				{ currencyType = "Gem", amount = 200 },
				{ currencyType = "BattlePassPoint", amount = 40 },
			},
		},
		[8] = {
			-- 스테이지 50회 클리어 (전체)
			index = 8,
			type = "StageClear",
			condition = "",
			progressCnt = 50,
			rewards = {
				{ currencyType = "Gem", amount = 300 },
				{ currencyType = "BattlePassPoint", amount = 60 },
			},
		},
		[9] = {
			-- 건물 100개 파괴
			index = 9,
			type = "PropDestroy",
			condition = "",
			progressCnt = 100,
			rewards = {
				{ currencyType = "Gem", amount = 150 },
				{ currencyType = "BattlePassPoint", amount = 30 },
			},
		},
		[10] = {
			-- NPC 50개 파괴
			index = 10,
			type = "NpcDestroy",
			condition = "",
			progressCnt = 50,
			rewards = {
				{ currencyType = "Gem", amount = 150 },
				{ currencyType = "BattlePassPoint", amount = 30 },
			},
		},
		[11] = {
			-- 일일 미션 30개 클리어
			index = 11,
			type = "MissionClear",
			condition = "",
			progressCnt = 30,
			rewards = {
				{ currencyType = "Gem", amount = 400 },
				{ currencyType = "BattlePassPoint", amount = 80 },
			},
		},
		[12] = {
			-- 2명과 20회 플레이
			index = 12,
			type = "PartyPlay",
			condition = "2",
			progressCnt = 20,
			rewards = {
				{ currencyType = "Gem", amount = 250 },
				{ currencyType = "BattlePassPoint", amount = 50 },
			},
		},
		[13] = {
			-- 유물 뽑기 50회
			index = 13,
			type = "RelicSummon",
			condition = "",
			progressCnt = 50,
			rewards = {
				{ currencyType = "Gem", amount = 200 },
				{ currencyType = "BattlePassPoint", amount = 40 },
			},
		},
		[14] = {
			-- A등급 유물 3개 획득
			index = 14,
			type = "RelicGradeCollect",
			condition = "A",
			progressCnt = 3,
			rewards = {
				{ currencyType = "Gem", amount = 500 },
				{ currencyType = "BattlePassPoint", amount = 100 },
			},
		},
	},
}
