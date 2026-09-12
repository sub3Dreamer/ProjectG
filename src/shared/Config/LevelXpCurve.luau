--[[
	Editable level XP curve.
	xpToNextByLevel[index] = XP needed to go from that level to the next level.
	Example: xpToNextByLevel[1] = 50 means level 1 -> 2 requires 50 XP.

	xpMultiplierByLevelDiff[diff] = 경험치 배율(그대로 곱함, % 아님).
	  diff = playerLevel - targetLevel(건물 Tier). AttackDamageCurve.damageMultiplierByLevelDiff와
	  같은 "260805 기획 밸런싱 표"의 경험치 컬럼 — 공격력과 반대 방향으로 움직인다:
	  diff < 0 (대상이 더 높음, 버거운 상대): 배율이 커짐(최대 9배) — 데미지는 약하지만 경험치는 후하게.
	  diff = 0 (동레벨): 1배.
	  diff > 0 (플레이어가 더 높음, 손쉬운 상대): 배율이 급격히 작아짐(최소 0.01배) — 데미지는
	  세지만 경험치 파밍은 억제.
	  정의된 범위(-9~9) 밖이면 가까운 끝 값으로 고정(diff<=-9 → -9행, diff>=9 → 9행).

	260821
	기획 밸런싱 표 (경험치 보정: 캐릭터 레벨 - 건물 티어)
	diff   배율
	-9     9
	-8     8
	-7     7
	-6     6
	-5     5
	-4     4
	-3     3
	-2     2
	-1     1.5
	 0     1
	 1     0.7
	 2     0.3
	 3     0.1
	 4     0.05
	 5     0.02
	 6     0.01
	 7     0.01
	 8     0.01
	 9     0.01
]]

return {
	meta = {
		startingLevel = 1,
		startingCumulativeXp = 0,
		maxLevel = 9,
	},
	xpToNextByLevel = {
		100, 200, 350, 550, 800,
		1100, 1450, 1850, 0,
	},

	xpMultiplierByLevelDiff = {
		[-9] = 9,
		[-8] = 8,
		[-7] = 7,
		[-6] = 6,
		[-5] = 5,
		[-4] = 4,
		[-3] = 3,
		[-2] = 2,
		[-1] = 1.5,
		[0] = 1,
		[1] = 0.1,
		[2] = 0.05,
		[3] = 0.02,
		[4] = 0.01,
		[5] = 0.01,
		[6] = 0.01,
		[7] = 0.01,
		[8] = 0.01,
		[9] = 0.01,
	},
}
