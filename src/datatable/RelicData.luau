--[[
	Rojo: src/datatable/RelicData.luau → ServerStorage.DataTable.RelicData

	relics 테이블 키 = id (number). 등급별로 4개씩.
	  D: Relic_01~04 (101~104)
	  C: Relic_05~08 (201~204)
	  B: Relic_09~12 (301~304)
	  A: Relic_13~16 (401~404)
	id: number, grade: RelicGrade — 우선 필드
	name: string — StringData 키 (표시명, 뒤 주석은 StringData.kr 실제 표시 텍스트)
	icon: string — ReplicatedStorage.Client.Relic 하위 아이콘 인스턴스 이름
	abilities: OptionData 참조 배열 — 등급 무관 1개.
	  각 항목: { type = OptionData.types 키, levels = { [1..4] = { stat1, stat2? } } }
	  levels 는 유물 레벨(RelicProgressEntry.level, 1~4)별 "증분" 수치 — 실제 적용치는 GameManager.
	  collectRelicOptionTotal 이 levels[1]..levels[N]을 누적 합산한 값이다 (levels[N] 단독 값이 아님).
	  예외: statCount==2 "주기 충전" 타입(FeverGaugeAutoCharge, XpAutoCharge)의 stat1(주기, 초)은
	  누적하지 않고 levels[N]의 값만 사용 — stat2(틱당 충전량)만 누적 합산 대상.
	  단, RelicPopup(레벨업 미리보기 UI)은 levels[N] 값을 그대로 미리보기로 보여주며 실제 누적 합산치와는
	  다를 수 있음 (의도된 동작, UI는 변경하지 않음).
	  등급이 높을수록(D<C<B<A) 같은 레벨에서의 stat 값도 더 높게 설정.
	  레벨 1~4 합계 상한(stat1만 있으면 stat1, stat1/stat2 둘 다 있으면 stat2 기준): D=10, C=15, B=20, A=30.
	  stat1/stat2가 모두 있는 "주기 충전" 타입(FeverGaugeAutoCharge, XpAutoCharge)의 stat1(충전 주기, 초)은
	  레벨과 무관하게 10으로 고정.
	  실제 문장 조립: StringHelper.format(StringHelper.get(OptionData.types[type].stringKey, locale), stat1, stat2)

	levelXpRequired: 현재 level → 다음 level 에 필요한 XP
	  [0]=lv.0→1 활성화, [3]=lv.3→4. lv.4 는 MAX(캡).
	  XP는 요구치 도달 후 수동 레벨업 전까지 계속 누적.

	summons 필드:
	  Normal  — D/C 등급 풀, Gold 소모
	  Special — B/A 등급 풀, Gem 소모
	  [1]  : 1회 뽑기 비용
	  [10] : 10회 뽑기 비용

	sets 필드 — 유물 세트 (등급별 1세트, 해당 등급 유물 4개 전부로 구성 — 기획상 최소 3~최대 5개 범위 충족).
	  grade: RelicGrade
	  relicIds: 세트를 구성하는 relics 키 배열
	  effect: 세트 완성 시 지급되는 패시브 1종 (이미 같은 type의 능력을 보유 중이면 수치 합산 — 합산 로직은 GameManager)
	    type: OptionData.types 키 — 세트 레벨이 올라도 type은 고정, stat만 상승.
	    levels: [1..4] = { stat1, requiredRelicLevel }
	      requiredRelicLevel — 세트 소속 유물 전원이 이 레벨 이상이어야 해당 세트 레벨 달성 (유물 레벨 상한 4에 맞춰 1/2/3/4로 설정).
	      stat1 — 해당 세트 레벨에서 적용되는 값 자체. 개별 유물 abilities.levels와 달리 "누적 합산"이 아니라
	      "레벨별 최종 수치"(상위 레벨 달성 시 이전 레벨 값을 대체)이다.
]]

return {
	relics = {
		-- D (Relic_01~04)
		[101] = {
			id = 101,
			grade = "D",
			name = "Relic_01",
			icon = "Material_Ore_01", -- 고대 철광석
			abilities = {
				{
					type = "FeverGaugeAutoCharge",
					levels = {
						[1] = { stat1 = 10, stat2 = 1 },
						[2] = { stat1 = 10, stat2 = 2 },
						[3] = { stat1 = 10, stat2 = 3 },
						[4] = { stat1 = 10, stat2 = 4 },
					},
				},
			},
		},
		[102] = {
			id = 102,
			grade = "D",
			name = "Relic_02",
			icon = "Item_Horseshoe_01_Silver", -- 은 편자
			abilities = {
				{
					type = "FeverDurationUp",
					levels = {
						[1] = { stat1 = 1 },
						[2] = { stat1 = 2 },
						[3] = { stat1 = 3 },
						[4] = { stat1 = 4 },
					},
				},
			},
		},
		[103] = {
			id = 103,
			grade = "D",
			name = "Relic_03",
			icon = "Item_Horn_01_Wood", -- 나무 뿔
			abilities = {
				{
					type = "FeverGaugeGainBonus",
					levels = {
						[1] = { stat1 = 1 },
						[2] = { stat1 = 2 },
						[3] = { stat1 = 3 },
						[4] = { stat1 = 4 },
					},
				},
			},
		},
		[104] = {
			id = 104,
			grade = "D",
			name = "Relic_04",
			icon = "Material_Ore_02_01", -- 불꽃모양 원석
			abilities = {
				{
					type = "FeverGaugeStageStart",
					levels = {
						[1] = { stat1 = 1 },
						[2] = { stat1 = 2 },
						[3] = { stat1 = 3 },
						[4] = { stat1 = 4 },
					},
				},
			},
		},
		-- C (Relic_05~08)
		[201] = {
			id = 201,
			grade = "C",
			name = "Relic_05",
			icon = "Item_HandMirror_01", -- 고대 손거울
			abilities = {
				{
					type = "StageRewardCurrencyUp",
					levels = {
						[1] = { stat1 = 2 },
						[2] = { stat1 = 3 },
						[3] = { stat1 = 4 },
						[4] = { stat1 = 6 },
					},
				},
			},
		},
		[202] = {
			id = 202,
			grade = "C",
			name = "Relic_06",
			icon = "Item_Compass_01_Silver", -- 은 나침반
			abilities = {
				{
					type = "AttackSpeedUp",
					levels = {
						[1] = { stat1 = 2 },
						[2] = { stat1 = 3 },
						[3] = { stat1 = 4 },
						[4] = { stat1 = 6 },
					},
				},
			},
		},
		[203] = {
			id = 203,
			grade = "C",
			name = "Relic_07",
			icon = "Item_Eye_01", -- 이블아이
			abilities = {
				{
					type = "StageRewardPassExpUp",
					levels = {
						[1] = { stat1 = 2 },
						[2] = { stat1 = 3 },
						[3] = { stat1 = 4 },
						[4] = { stat1 = 6 },
					},
				},
			},
		},
		[204] = {
			id = 204,
			grade = "C",
			name = "Relic_08",
			icon = "Item_Compass_01_Gold", -- 황금 나침반
			abilities = {
				{
					type = "MoveSpeedUp",
					levels = {
						[1] = { stat1 = 2 },
						[2] = { stat1 = 3 },
						[3] = { stat1 = 4 },
						[4] = { stat1 = 6 },
					},
				},
			},
		},
		-- B (Relic_09~12)
		[301] = {
			id = 301,
			grade = "B",
			name = "Relic_09",
			icon = "Gear_Bow_01", -- 다물 활
			abilities = {
				{
					type = "XpAutoCharge",
					levels = {
						[1] = { stat1 = 10, stat2 = 2 },
						[2] = { stat1 = 10, stat2 = 4 },
						[3] = { stat1 = 10, stat2 = 6 },
						[4] = { stat1 = 10, stat2 = 8 },
					},
				},
			},
		},
		[302] = {
			id = 302,
			grade = "B",
			name = "Relic_10",
			icon = "Gear_Chest_01", -- 고대 철갑옷
			abilities = {
				{
					type = "XpChargeOnLevelUp",
					levels = {
						[1] = { stat1 = 2 },
						[2] = { stat1 = 4 },
						[3] = { stat1 = 6 },
						[4] = { stat1 = 8 },
					},
				},
			},
		},
		[303] = {
			id = 303,
			grade = "B",
			name = "Relic_11",
			icon = "Misc_Earth_01", -- 지구본
			abilities = {
				{
					type = "XpGainBonusOnDestroy",
					levels = {
						[1] = { stat1 = 2 },
						[2] = { stat1 = 4 },
						[3] = { stat1 = 6 },
						[4] = { stat1 = 8 },
					},
				},
			},
		},
		[304] = {
			id = 304,
			grade = "B",
			name = "Relic_12",
			icon = "Gear_Ring_01_Silver", -- 은빛 반지
			abilities = {
				{
					type = "XpStageStart",
					levels = {
						[1] = { stat1 = 2 },
						[2] = { stat1 = 4 },
						[3] = { stat1 = 6 },
						[4] = { stat1 = 8 },
					},
				},
			},
		},
		-- A (Relic_13~16)
		[401] = {
			id = 401,
			grade = "A",
			name = "Relic_13",
			icon = "Gear_Ring_01_Silver", -- 금빛 반지
			abilities = {
				{
					type = "AttackSpeedUp",
					levels = {
						[1] = { stat1 = 3 },
						[2] = { stat1 = 6 },
						[3] = { stat1 = 9 },
						[4] = { stat1 = 12 },
					},
				},
			},
		},
		[402] = {
			id = 402,
			grade = "A",
			name = "Relic_14",
			icon = "Gear_Weapons_Sword_01", -- 날카로운 검
			abilities = {
				{
					type = "StageRewardPassExpUp",
					levels = {
						[1] = { stat1 = 3 },
						[2] = { stat1 = 6 },
						[3] = { stat1 = 9 },
						[4] = { stat1 = 12 },
					},
				},
			},
		},
		[403] = {
			id = 403,
			grade = "A",
			name = "Relic_15",
			icon = "Gear_Helmet_03", -- 그리폰의 투구
			abilities = {
				{
					type = "MoveSpeedUp",
					levels = {
						[1] = { stat1 = 3 },
						[2] = { stat1 = 6 },
						[3] = { stat1 = 9 },
						[4] = { stat1 = 12 },
					},
				},
			},
		},
		[404] = {
			id = 404,
			grade = "A",
			name = "Relic_16",
			icon = "Gear_Helmet_04", -- 성기사의 투구
			abilities = {
				{
					type = "FeverGaugeAutoCharge",
					levels = {
						[1] = { stat1 = 10, stat2 = 3 },
						[2] = { stat1 = 10, stat2 = 6 },
						[3] = { stat1 = 10, stat2 = 9 },
						[4] = { stat1 = 10, stat2 = 12 },
					},
				},
			},
		},
	},

	sets = {
		SetD = {
			grade = "D",
			relicIds = { 101, 102, 103, 104 },
			effect = {
				type = "MoveSpeedUp",
				levels = {
					[1] = { stat1 = 1, requiredRelicLevel = 1 },
					[2] = { stat1 = 2, requiredRelicLevel = 2 },
					[3] = { stat1 = 3, requiredRelicLevel = 3 },
					[4] = { stat1 = 4, requiredRelicLevel = 4 },
				},
			},
		},
		SetC = {
			grade = "C",
			relicIds = { 201, 202, 203, 204 },
			effect = {
				type = "AttackSpeedUp",
				levels = {
					[1] = { stat1 = 2, requiredRelicLevel = 1 },
					[2] = { stat1 = 3, requiredRelicLevel = 2 },
					[3] = { stat1 = 4, requiredRelicLevel = 3 },
					[4] = { stat1 = 6, requiredRelicLevel = 4 },
				},
			},
		},
		SetB = {
			grade = "B",
			relicIds = { 301, 302, 303, 304 },
			effect = {
				type = "FeverDurationUp",
				levels = {
					[1] = { stat1 = 2, requiredRelicLevel = 1 },
					[2] = { stat1 = 4, requiredRelicLevel = 2 },
					[3] = { stat1 = 6, requiredRelicLevel = 3 },
					[4] = { stat1 = 8, requiredRelicLevel = 4 },
				},
			},
		},
		SetA = {
			grade = "A",
			relicIds = { 401, 402, 403, 404 },
			effect = {
				type = "XpGainBonusOnDestroy",
				levels = {
					[1] = { stat1 = 3, requiredRelicLevel = 1 },
					[2] = { stat1 = 6, requiredRelicLevel = 2 },
					[3] = { stat1 = 9, requiredRelicLevel = 3 },
					[4] = { stat1 = 12, requiredRelicLevel = 4 },
				},
			},
		},
	},

	levelXpRequired = {
		[0] = 10, -- lv.0 → lv.1 (활성화)
		[1] = 30, -- lv.1 → lv.2
		[2] = 50, -- lv.2 → lv.3
		[3] = 70, -- lv.3 → lv.4 (MAX)
	},

	summons = {
		-- Normal: D/C 등급, Gold 소모
		Normal = {
			[1] = { currencyType = "Gold", amount = 100 }, -- 1회 뽑기
			[10] = { currencyType = "Gold", amount = 1000 }, -- 10회 뽑기
		},
		-- Special: B/A 등급, Gem 소모
		Special = {
			[1] = { currencyType = "Gem", amount = 100 }, -- 1회 뽑기
			[10] = { currencyType = "Gem", amount = 1000 }, -- 10회 뽑기
		},
	},
}
