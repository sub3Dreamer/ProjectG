--[[
	Rojo: src/datatable/OptionData.luau → ServerStorage.DataTable.OptionData

	types — 옵션 타입별 마스터 정의 (stringKey, statCount)

	실제 옵션 수치(stat1, stat2)는 여기 없음 — 이 테이블을 참조하는 각 콘텐츠 테이블
	(유물/아이템 등)이 type + stat1(+stat2) 필드를 들고 있다가 여기서 stringKey를 찾아
	StringHelper.format(StringHelper.get(stringKey, locale), stat1, stat2) 로 문장을 조립한다.

	statCount — 포맷에서 쓰는 stat 개수 (1 또는 2). 1이면 stat1만, 2면 stat1/stat2 모두 사용.
]]

return {
	types = {
		-- N초마다 피버 게이지 N% 충전
		FeverGaugeAutoCharge = { stringKey = "Option_FeverGaugeAutoCharge", statCount = 2 },
		-- 피버모드 유지 시간 N초 증가
		FeverDurationUp = { stringKey = "Option_FeverDurationUp", statCount = 1 },
		-- 피버 게이지 획득 시마다 N% 추가 획득
		FeverGaugeGainBonus = { stringKey = "Option_FeverGaugeGainBonus", statCount = 1 },
		-- 피버 게이지 N%를 획득한 상태로 스테이지 시작
		FeverGaugeStageStart = { stringKey = "Option_FeverGaugeStageStart", statCount = 1 },
		-- 스테이지 클리어 보상 재화 N% 추가 획득
		StageRewardCurrencyUp = { stringKey = "Option_StageRewardCurrencyUp", statCount = 1 },
		-- 공격 속도 N% 증가
		AttackSpeedUp = { stringKey = "Option_AttackSpeedUp", statCount = 1 },
		-- 스테이지 클리어 보상 패스 경험치 N% 증가
		StageRewardPassExpUp = { stringKey = "Option_StageRewardPassExpUp", statCount = 1 },
		-- 이동 속도 N% 증가
		MoveSpeedUp = { stringKey = "Option_MoveSpeedUp", statCount = 1 },
		-- N초마다 경험치 N만큼 충전
		XpAutoCharge = { stringKey = "Option_XpAutoCharge", statCount = 2 },
		-- 레벨업 후 경험치 N만큼 충전
		XpChargeOnLevelUp = { stringKey = "Option_XpChargeOnLevelUp", statCount = 1 },
		-- 오브젝트 파괴 시 경험치 N% 추가 획득
		XpGainBonusOnDestroy = { stringKey = "Option_XpGainBonusOnDestroy", statCount = 1 },
		-- 경험치 N만큼 획득한 상태로 스테이지 시작
		XpStageStart = { stringKey = "Option_XpStageStart", statCount = 1 },
	},
}
