--[[
	Editable character scale curve.
	scaleByLevel[index] = character model scale for that level.
	Example: scaleByLevel[3] = 3.4 means level 3 uses model scale 3.4.
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
	Level1 : 1.2
	Level2 : 2.1
	Level3 : 3.1
	Level4 : 4.8
	Level5 : 7.5
	Level6 : 12
	Level7 : 18
	Level8 : 27
	Level9 : 43
]]

return {
	meta = {
		startingLevel = 1,
		maxLevel = 9,
	},
	scaleByLevel = {
		1.2,
		2.1,
		3.1,
		4.8,
		7.5,
		12,
		18,
		27,
		43,
	},
}
