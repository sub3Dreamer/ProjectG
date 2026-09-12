--[[
	Rojo: src/datatable/MissionData.luau → ServerStorage.DataTable.MissionData

	missions 테이블 키(index)는 1 이상 정수. 개수·index 범위는 자유 (연속일 필요 없음).

	미션 필드:
	  index       : number  — 미션 인덱스
	  stringKey   : string  — StringData 조회 키
	  progressCnt : number  — 목표 진행 횟수
	  rewards     : { { currencyType: string, amount: number } }  — 완료 보상 목록
]]

return {
	missions = {
		[1] = {
			-- 스테이지 n회 클리어
			index = 1,
			stringKey = "Mission_01",
			progressCnt = 3,
			rewards = {
				{ currencyType = "Gold", amount = 3000 },
				{ currencyType = "BattlePassPoint", amount = 30 },
			},
		},
		[2] = {
			-- 건물 n개 파괴
			index = 2,
			stringKey = "Mission_02",
			progressCnt = 3000,
			rewards = {
				{ currencyType = "Gold", amount = 3000 },
				{ currencyType = "BattlePassPoint", amount = 30 },
			},
		},
		[3] = {
			-- 피버 타임 n회 체험
			index = 3,
			stringKey = "Mission_03",
			progressCnt = 15,
			rewards = {
				{ currencyType = "Gem", amount = 100 },
				{ currencyType = "BattlePassPoint", amount = 15 },
			},
		},
		[4] = {
			-- 펀치(수동 공격)로 건물 n개 파괴
			index = 4,
			stringKey = "Mission_04",
			progressCnt = 1500,
			rewards = {
				{ currencyType = "Gold", amount = 2000 },
				{ currencyType = "BattlePassPoint", amount = 15 },
			},
		},
		[5] = {
			-- 발(트램플)로 건물 n개 파괴
			index = 5,
			stringKey = "Mission_05",
			progressCnt = 1500,
			rewards = {
				{ currencyType = "Gold", amount = 2500 },
				{ currencyType = "BattlePassPoint", amount = 20 },
			},
		},
		[6] = {
			-- 펫 n마리 구출 (하루 누적)
			index = 6,
			stringKey = "Mission_06",
			progressCnt = 30,
			rewards = {
				{ currencyType = "Gem", amount = 150 },
				{ currencyType = "BattlePassPoint", amount = 30 },
			},
		},
	},
}
