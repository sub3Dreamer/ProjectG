--[[
	Editable attack damage curve.
	damageByLevel[index] = attack damage for that player level.
	Current rule: base damage 50 x level.

	damageMultiplierByLevelDiff[diff] = 데미지 배율(그대로 곱함, % 아님).
	  diff = playerLevel - targetLevel.
	  diff < 0 (대상이 더 높음): 점점 작아지는 배율(디버프).
	  diff = 0 (동레벨): 1배.
	  diff > 0 (플레이어가 더 높음): 5배 고정(하드 캐리 보너스).
	  정의된 범위(-9~9) 밖이면 가까운 끝 값(diff<=-9 → -9행, diff>=9 → 9행)으로 고정.
	  최종 = floor( baseDamage * 배율 + 0.5 ), 이후 CombatHandler에서 최소 1 데미지 보장.
]]

--[[추후 개발 스펙
	경험치 당 Scale/Dmg 증가량
	Level1 : 1.0 -> 1.2 / 50 -> 70
	Level2 : 1.8 -> 2.1 / 100 -> 120
	Level3 : 2.8 -> 3.1 / 150 -> 170
	Level4 : 4.5 -> 4.8 / 200 -> 220
	Level5 : 7.5 -> 7.8 / 250 -> 270
	Level6 : 11.0 -> 12.0 / 300 -> 320
	Level7 : 17.0 -> 18.0 / 400 -> 440
	Level8 : 26.0 -> 28.0 / 550 -> 600
	Level9 : 34.0 / 700

	※ 현재 아이디어 단계, 일단 기본수치만 적용하고 증가량은 회의 때 방향성 결정되면 적용 필요!

	260804
	Level1 : 20
	Level2 : 40
	Level3 : 75
	Level4 : 140
	Level5 : 260
	Level6 : 480
	Level7 : 880
	Level8 : 1600
	Level9 : 3000

	260805
	기획 밸런싱 표 (공격력 보정: 캐릭터 레벨 - 건물 티어)
	diff   배율
	-9     0.005
	-8     0.01
	-7     0.02
	-6     0.05
	-5     0.1
	-4     0.2
	-3     0.4
	-2     0.6
	-1     0.8
		0     1
		1     5
		2     5
		3     5
		4     5
		5     5
		6     5
		7     5
		8     5
		9     5
]]

return {
	meta = {
		startingLevel = 1,
		maxLevel = 9,
	},
	damageByLevel = {
		20,
		40,
		75,
		140,
		260,
		480,
		880,
		1600,
		3000,
	},

	damageMultiplierByLevelDiff = {
		[-9] = 0.005,
		[-8] = 0.01,
		[-7] = 0.02,
		[-6] = 0.05,
		[-5] = 0.1,
		[-4] = 0.2,
		[-3] = 0.4,
		[-2] = 0.6,
		[-1] = 0.8,
		[0] = 1,
		[1] = 5,
		[2] = 5,
		[3] = 5,
		[4] = 5,
		[5] = 5,
		[6] = 5,
		[7] = 5,
		[8] = 5,
		[9] = 5,
	},
}
