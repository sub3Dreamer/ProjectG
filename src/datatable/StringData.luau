--[[
	Rojo: src/datatable/StringData.luau → ServerStorage.DataTable.StringData
	클라이언트: DataManager.init() 시 ReplicatedStorage.DataTable 로 복제

	strings 테이블은 key 문자열을 인덱스로 사용 — strings[key] 로 O(1) 조회.

	항목 필드:
	  key : string — 조회용 식별자 (테이블 키와 동일하게 유지)
	  kr  : string — 한국어 (게임 표시용)

	사용 예:
	  local row = StringData.strings["Lobby_Mission"]
	  local text = row.kr
]]

return {
	strings = {
		-- 미션 관련
		["Mission_01"] = {
			key = "Mission_01",
			kr = "스테이지 {0}회 클리어",
		},
		["Mission_02"] = {
			key = "Mission_02",
			kr = "건물 {0}개 파괴",
		},
		["Mission_03"] = {
			key = "Mission_03",
			kr = "피버 타임 {0}회 체험",
		},
		["Mission_04"] = {
			key = "Mission_04",
			kr = "펀치로 건물 {0}개 파괴",
		},
		["Mission_05"] = {
			key = "Mission_05",
			kr = "발로 건물 {0}개 파괴",
		},
		["Mission_06"] = {
			key = "Mission_06",
			kr = "펫 {0}마리 구출",
		},

		-- 업적 관련 (타입별 stringKey — AchievementData.types 와 동일 키)
		["Achievement_GetGold"] = {
			key = "Achievement_GetGold",
			kr = "골드 {0}개 획득",
		},
		["Achievement_Attendance"] = {
			key = "Achievement_Attendance",
			kr = "게임 접속 {0}일",
		},
		["Achievement_StageTimeClear"] = {
			key = "Achievement_StageTimeClear",
			kr = "스테이지{0} {1}초 이내 클리어",
		},
		["Achievement_TargetStageClear"] = {
			key = "Achievement_TargetStageClear",
			kr = "스테이지{0} {1}회 클리어",
		},
		["Achievement_Fever"] = {
			key = "Achievement_Fever",
			kr = "피버 타임 {0}회 체험",
		},
		["Achievement_StageClear"] = {
			key = "Achievement_StageClear",
			kr = "스테이지 {0}회 클리어",
		},
		["Achievement_PropDestroy"] = {
			key = "Achievement_PropDestroy",
			kr = "건물 {0}개 파괴",
		},
		["Achievement_NpcDestroy"] = {
			key = "Achievement_NpcDestroy",
			kr = "NPC {0}개 파괴",
		},
		["Achievement_TargetPropDestroy"] = {
			key = "Achievement_TargetPropDestroy",
			kr = "건물 {0} {1}회 파괴",
		},
		["Achievement_MissionClear"] = {
			key = "Achievement_MissionClear",
			kr = "일일 미션 {0}개 클리어",
		},
		["Achievement_PartyPlay"] = {
			key = "Achievement_PartyPlay",
			kr = "{0}명과 {1}회 플레이",
		},
		["Achievement_RelicSummon"] = {
			key = "Achievement_RelicSummon",
			kr = "유물 뽑기 {0}회 진행",
		},
		["Achievement_RelicGradeCollect"] = {
			key = "Achievement_RelicGradeCollect",
			kr = "{0}등급 유물 {1}개 획득",
		},

		-- 옵션 관련 (타입별 stringKey — OptionData.types 와 동일 키)
		["Option_FeverGaugeAutoCharge"] = {
			key = "Option_FeverGaugeAutoCharge",
			kr = "{0}초마다 피버 게이지 {1}% 충전",
		},
		["Option_FeverDurationUp"] = {
			key = "Option_FeverDurationUp",
			kr = "피버 모드 유지 시간 {0}초 증가",
		},
		["Option_FeverGaugeGainBonus"] = {
			key = "Option_FeverGaugeGainBonus",
			kr = "피버 게이지 획득 시마다 {0}% 추가 획득",
		},
		["Option_FeverGaugeStageStart"] = {
			key = "Option_FeverGaugeStageStart",
			kr = "피버 게이지 {0}%를 획득한 상태로 스테이지 시작",
		},
		["Option_StageRewardCurrencyUp"] = {
			key = "Option_StageRewardCurrencyUp",
			kr = "스테이지 클리어 보상으로 획득하는 재화 {0}% 추가 획득",
		},
		["Option_AttackSpeedUp"] = {
			key = "Option_AttackSpeedUp",
			kr = "공격 속도 {0}% 증가",
		},
		["Option_StageRewardPassExpUp"] = {
			key = "Option_StageRewardPassExpUp",
			kr = "스테이지 클리어 보상으로 획득하는 패스 경험치 {0}% 증가",
		},
		["Option_MoveSpeedUp"] = {
			key = "Option_MoveSpeedUp",
			kr = "이동 속도 {0}% 증가",
		},
		["Option_XpAutoCharge"] = {
			key = "Option_XpAutoCharge",
			kr = "{0}초마다 경험치 {1}만큼 충전",
		},
		["Option_XpChargeOnLevelUp"] = {
			key = "Option_XpChargeOnLevelUp",
			kr = "레벨업 후 경험치 {0}만큼 충전",
		},
		["Option_XpGainBonusOnDestroy"] = {
			key = "Option_XpGainBonusOnDestroy",
			kr = "건물 파괴 시 경험치 {0}% 추가 획득",
		},
		["Option_XpStageStart"] = {
			key = "Option_XpStageStart",
			kr = "경험치 {0}만큼 획득한 상태로 스테이지 시작",
		},

		-- 스테이지 이름 (StageData.stages 와 동일 키 stageNumber, 구 StageConfig.luau 리터럴 이관)
		["Stage_01_Name"] = {
			key = "Stage_01_Name",
			kr = "스테이지 1 - 파리",
		},
		["Stage_02_Name"] = {
			key = "Stage_02_Name",
			kr = "스테이지 2 - 서울",
		},
		["Stage_03_Name"] = {
			key = "Stage_03_Name",
			kr = "스테이지 3 - 도쿄",
		},

		-- UI 키값
		["TxtRemainTime"] = {
			key = "TxtRemainTime",
			kr = "마감까지 남은 시간 {0}",
		},
		["Time_Hour_Format"] = {
			key = "Time_Hour_Format",
			kr = "{0}시간",
		},
		["Time_Day_Format"] = {
			key = "Time_Day_Format",
			kr = "{0}일",
		},
		["Time_Minute_Format"] = {
			key = "Time_Minute_Format",
			kr = "{0}분",
		},
		["Time_Second_Format"] = {
			key = "Time_Second_Format",
			kr = "{0}초",
		},

		-- 로비 LobbyScreenGui 버튼 라벨
		["Lobby_Mission"] = {
			key = "Lobby_Mission",
			kr = "미션",
		},
		["Lobby_Achievement"] = {
			key = "Lobby_Achievement",
			kr = "업적",
		},
		["Lobby_Inventory"] = {
			key = "Lobby_Inventory",
			kr = "인벤토리",
		},
		["Lobby_Daily"] = {
			key = "Lobby_Daily",
			kr = "출석",
		},
		["Lobby_Shop"] = {
			key = "Lobby_Shop",
			kr = "상점",
		},
		["Lobby_Setting"] = {
			key = "Lobby_Setting",
			kr = "설정",
		},
		["Lobby_BattlePass"] = {
			key = "Lobby_BattlePass",
			kr = "배틀패스",
		},
		["Lobby_Relic"] = {
			key = "Lobby_Relic",
			kr = "유물",
		},
		["Lobby_Costume"] = {
			key = "Lobby_Costume",
			kr = "코스튬",
		},
		["Lobby_Gacha"] = {
			key = "Lobby_Gacha",
			kr = "뽑기",
		},

		-- 재화
		["Gold"] = {
			key = "Gold",
			kr = "골드",
		},
		["Gem"] = {
			key = "Gem",
			kr = "루비",
		},
		["BattlePassPoint"] = {
			key = "BattlePassPoint",
			kr = "침략자 포인트",
		},

		-- RelicPopup
		["RelicSummon_NormalTitle"] = {
			key = "RelicSummon_NormalTitle",
			kr = "일반 유물 뽑기",
		},
		["RelicSummon_SpecialTitle"] = {
			key = "RelicSummon_SpecialTitle",
			kr = "고급 유물 뽑기",
		},
		["RelicSummon_NormalDesc"] = {
			key = "RelicSummon_NormalDesc",
			kr = "D~C등급 유물 획득",
		},
		["RelicSummon_SpecialDesc"] = {
			key = "RelicSummon_SpecialDesc",
			kr = "B~A등급 유물 획득",
		},
		["RelicSummon_One"] = {
			key = "RelicSummon_One",
			kr = "1회 뽑기",
		},
		["RelicSummon_Ten"] = {
			key = "RelicSummon_Ten",
			kr = "10회 뽑기",
		},
		["SetD"] = {
			key = "SetD",
			kr = "D세트",
		},
		["SetC"] = {
			key = "SetC",
			kr = "C세트",
		},
		["SetB"] = {
			key = "SetB",
			kr = "B세트",
		},
		["SetA"] = {
			key = "SetA",
			kr = "A세트",
		},
		["Remain_Piece"] = {
			key = "Remain_Piece",
			kr = "남은 조각",
		},
		["Tab_Collection"] = {
			key = "Tab_Collection",
			kr = "컬렉션",
		},
		["Tab_Set"] = {
			key = "Tab_Set",
			kr = "세트",
		},

		-- RelicSummonPopup
		["RelicSummon_TapNext"] = {
			key = "RelicSummon_TapNext",
			kr = "탭하여 다음 열기",
		},
		["RelicSummon_TapClose"] = {
			key = "RelicSummon_TapClose",
			kr = "아무 곳이나 클릭하여 닫기",
		},
		["RelicGrade_D"] = {
			key = "RelicGrade_D",
			kr = "D등급",
		},
		["RelicGrade_C"] = {
			key = "RelicGrade_C",
			kr = "C등급",
		},
		["RelicGrade_B"] = {
			key = "RelicGrade_B",
			kr = "B등급",
		},
		["RelicGrade_A"] = {
			key = "RelicGrade_A",
			kr = "A등급",
		},

		-- RelicData.name
		["Relic_01"] = {
			key = "Relic_01",
			kr = "고대 철광석",
		},
		["Relic_02"] = {
			key = "Relic_02",
			kr = "은 편자",
		},
		["Relic_03"] = {
			key = "Relic_03",
			kr = "나무 뿔",
		},
		["Relic_04"] = {
			key = "Relic_04",
			kr = "불꽃모양 원석",
		},
		["Relic_05"] = {
			key = "Relic_05",
			kr = "고대 손거울",
		},
		["Relic_06"] = {
			key = "Relic_06",
			kr = "은 나침반",
		},
		["Relic_07"] = {
			key = "Relic_07",
			kr = "이블아이",
		},
		["Relic_08"] = {
			key = "Relic_08",
			kr = "황금 나침반",
		},
		["Relic_09"] = {
			key = "Relic_09",
			kr = "다물 활",
		},
		["Relic_10"] = {
			key = "Relic_10",
			kr = "고대 철갑옷",
		},
		["Relic_11"] = {
			key = "Relic_11",
			kr = "지구본",
		},
		["Relic_12"] = {
			key = "Relic_12",
			kr = "은빛 반지",
		},
		["Relic_13"] = {
			key = "Relic_13",
			kr = "금빛 반지",
		},
		["Relic_14"] = {
			key = "Relic_14",
			kr = "날카로운 검",
		},
		["Relic_15"] = {
			key = "Relic_15",
			kr = "그리폰의 투구",
		},
		["Relic_16"] = {
			key = "Relic_16",
			kr = "성기사의 투구",
		},

		-- 펫
		["Pet_01"] = {
			key = "Pet_01",
			kr = "꿀꿀이",
		},
		["Pet_02"] = {
			key = "Pet_02",
			kr = "토끼",
		},
		["Pet_03"] = {
			key = "Pet_03",
			kr = "야옹이",
		},
		["Pet_04"] = {
			key = "Pet_04",
			kr = "도지",
		},
		["Pet_05"] = {
			key = "Pet_05",
			kr = "치와와",
		},
		["Pet_06"] = {
			key = "Pet_06",
			kr = "하늘핑",
		},
		["Pet_07"] = {
			key = "Pet_07",
			kr = "유령새",
		},
		["Pet_08"] = {
			key = "Pet_08",
			kr = "버터플",
		},
		["Pet_09"] = {
			key = "Pet_09",
			kr = "너드새",
		},
		["Pet_10"] = {
			key = "Pet_10",
			kr = "앵무새",
		},

		-- 아이템
		["SpeedUp_Title"] = {
			key = "SpeedUp_Title",
			kr = "속도 증가",
		},
		["SpeedUp_Desc"] = {
			key = "SpeedUp_Desc",
			kr = "이동 속도가 50% 증가합니다.",
		},
		["FeverGaugeUp_Title"] = {
			key = "FeverGaugeUp_Title",
			kr = "피버 게이지 증가",
		},
		["FeverGaugeUp_Desc"] = {
			key = "FeverGaugeUp_Desc",
			kr = "피버 게이지를 50% 충전합니다.",
		},
		["FeverGaugeMax_Title"] = {
			key = "FeverGaugeMax_Title",
			kr = "피버 게이지 풀충전",
		},
		["FeverGaugeMax_Desc"] = {
			key = "FeverGaugeMax_Desc",
			kr = "피버 게이지를 최대로 충전합니다.",
		},
		["RelicNormalKey_Title"] = {
			key = "RelicNormalKey_Title",
			kr = "유물 일반 상자 열쇠",
		},
		["RelicNormalKey_Desc"] = {
			key = "RelicNormalKey_Desc",
			kr = "일반 유물 상자를 개방하는 데 사용합니다.",
		},
		["RelicSpecialKey_Title"] = {
			key = "RelicSpecialKey_Title",
			kr = "유물 고급 상자 열쇠",
		},
		["RelicSpecialKey_Desc"] = {
			key = "RelicSpecialKey_Desc",
			kr = "고급 유물 상자를 개방하는 데 사용합니다.",
		},

		-- 코스튬
		["Costume_01"] = {
			key = "Costume_01",
			kr = "검은 고양이 네로",
		},
		["Costume_02"] = {
			key = "Costume_02",
			kr = "블루 토끼냥",
		},
		["Costume_03"] = {
			key = "Costume_03",
			kr = "갈색 곰돌이",
		},
		["Costume_04"] = {
			key = "Costume_04",
			kr = "블루 우파루파",
		},
		["Costume_05"] = {
			key = "Costume_05",
			kr = "그림자 보안관",
		},
		["Costume_06"] = {
			key = "Costume_06",
			kr = "강아지 로봇 후드",
		},
		["Costume_07"] = {
			key = "Costume_07",
			kr = "암살자 수트",
		},
		["Costume_08"] = {
			key = "Costume_08",
			kr = "젖소무늬 코스튬(M)",
		},
		["Costume_09"] = {
			key = "Costume_09",
			kr = "젖소무늬 코스튬(F)",
		},
		["Costume_10"] = {
			key = "Costume_10",
			kr = "검은 토끼",
		},

		-- CostumePopup
		["Tab_Marketplace"] = {
			key = "Tab_Marketplace",
			kr = "마켓플레이스",
		},
		["Tab_Closet"] = {
			key = "Tab_Closet",
			kr = "옷장",
		},

		-- 난이도 (PartyPopup, RoomManager)
		["Difficulty_Easy"] = {
			key = "Difficulty_Easy",
			kr = "쉬움",
		},
		["Difficulty_Normal"] = {
			key = "Difficulty_Normal",
			kr = "일반",
		},
		["Difficulty_Hard"] = {
			key = "Difficulty_Hard",
			kr = "어려움",
		},

		-- PartyPopup
		["Party_StageFormat"] = {
			key = "Party_StageFormat",
			kr = "스테이지 : Stage{0}",
		},
		["Party_DifficultyFormat"] = {
			key = "Party_DifficultyFormat",
			kr = "난이도 : {0}",
		},
		["Party_AutoCreateTimer"] = {
			key = "Party_AutoCreateTimer",
			kr = "{0}초 후에 자동 생성 예정",
		},

		-- PortalUI
		["Portal_Preparing"] = {
			key = "Portal_Preparing",
			kr = "제작 중...",
		},
		["Portal_Teleporting"] = {
			key = "Portal_Teleporting",
			kr = "순간 이동 중...",
		},

		-- Stage
		["PetTimer_UFO_Notice"] = {
			key = "PetTimer_UFO_Notice",
			kr = "우주선 등장까지 : %d초",
		},
		["PetTimer_PetMarker_Notice"] = {
			key = "PetTimer_PetMarker_Notice",
			kr = "펫 구출까지 : %d초",
		},
	},
}
