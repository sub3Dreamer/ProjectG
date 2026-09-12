return {
	MaxPlayersPerStage = 10,
	StageClearTimeout = 300,
	RespawnTime = 5,

	Scale = {
		PlayerScale = 1,
		MinScale = 1,
		MaxScale = 52.2,
		-- R15: Model:ScaleTo 대신 Humanoid Body*Scale (Animate·Idle 지면 보정과 호환)
		UseHumanoidBodyScaleForR15 = true,
		-- 정지·Idle 중 발이 땅에 묻히면 레이캐스트로 보정 (서버)
		StandingGroundAlign = false,
		StandingAlignInterval = 0.12,
		StandingAlignMaxStepStuds = 6,
	},

	-- 스테이지 플레이 시작 시 서버가 생성하는 투명 사각 벽 (맵 2048×2048 기준: half=1024)
	ArenaWalls = {
		Center = Vector3.new(0, 0, 0), -- XZ: 맵 중심, Y: 벽 하단(월드 Y, 맵 바닥에 맞게 조정)
		HalfExtentsX = 1024,
		HalfExtentsZ = 1024,
		Thickness = 24,
		CharacterHeightAtScale1Studs = 14,
		ExtraHeightStuds = 200,
	},

	-- 레벨업 구간 XP는 `LevelXpCurve.luau`. 여기서는 오브젝트 파괴 보상 배수만 둠
	XP = {
		-- 파괴한 오브젝트 Level 1단계당 기본 XP에 곱함 (총합 = 기본 x 오브젝트 Level)
		XpPerLevelDestroyed = 10,
	},

	Camera = {
		BaseDistance = 10, -- 스케일 1일 때 고정 카메라 거리
		DistancePerScale = 7, -- 스케일이 1 커질 때마다 뒤로 빠지는 거리 (260901수정 5->7로 변경)
	},

	-- 밟을 때 작은 물체에 밀려 떨어지는 느낌 완화
	CharacterStability = {
		Enabled = true,
		HumanoidRootPartDensity = 2.2,
		HumanoidRootPartFriction = 1.85,
		LimbDensity = 0.7,
		LimbFriction = 1.75,
		Elasticity = 0,
		StepHeight = 0,
		-- scale>1일 때 StepHeight = max(StepHeight, StepHeightPerScale * scale). 작은 스케일은 StepHeight 유지
		StepHeightPerScale = 0.07,
		-- false: LocomotionAnimPreload(R6/R15) 임시 비활성
		LocomotionSystemsEnabled = true,
		-- 플레이어 걷기 애니 (Animate/walk, RigType별)
		WalkAnimations = {
			R15 = "rbxassetid://122826910422821",
			R6 = "rbxassetid://78251768254078",
		},
	},

	Combat = {
		-- 공격 애니메이션 (캐릭터 RigType에 따라 CombatController가 R6/R15 중 선택)
		AttackAnimations = {
			R15 = {
				"rbxassetid://74745994117175", -- 오른쪽 공격 R15
				"rbxassetid://93837860418398", -- 왼쪽 공격 R15
			},
			R6 = {
				"rbxassetid://97981213010585", -- 오른쪽 공격 R6
				"rbxassetid://96168587746523", -- 왼쪽 공격 R6
			},
		},
		-- 밟기 애니메이션 (캐릭터 RigType에 따라 R6/R15 중 선택)
		StompAnimations = {
			R15 = {
				"rbxassetid://88249030107344", -- 오른쪽 밟기 R15
				"rbxassetid://93820770823641", -- 왼쪽 밟기 R15
			},
			R6 = {
				"rbxassetid://114654169544231", -- 오른쪽 밟기 R6
				"rbxassetid://111294777177205", -- 왼쪽 밟기 R6
			},
		},
		-- 피버 시작 애니메이션 (캐릭터 RigType에 따라 R6/R15 중 선택)
		FeverAnimation = {
			R15 = "rbxassetid://71389383019980",
			R6 = "rbxassetid://114398848986616",
			InputLockSeconds = 1, -- 피버 시작 애니 중 이동·공격·밟기 차단
			DurationSeconds = 1, -- 피버 타이머 차감 시작 전 대기(애니 길이와 맞춤)
		},
		-- false면 자동 밟기 밟기 애니 미재생 (테스트용, 원복 시 true)
		StompAnimationsEnabled = true,
		AttackCooldown = 0.4,		-- 애니 지속시간 0.6초 (연타시 애니 시간 80% 쯤에서 블렌딩)
		AttackHitDelay = 0.3,
		AttackRange = 3,
		AttackBoxScale = Vector3.new(1, 1.5, 1), -- Y를 키우면 위아래로 더 넓어짐
		AttackOffset = Vector3.new(0, -0.75, -1),
		HitPointConfigAttributeName = "HitPoint",
		CurrentHitPointAttributeName = "CurrentHitPoint",
		MaxHitPointAttributeName = "MaxHitPoint",
		TierAttributeName = "Tier",
		RewardXpAttributeName = "XP",
		-- Attribute boolean true인 데미지 가능 Model이 파괴되면 스테이지 클리어(타이머·진행 종료 + GameClearPopup)
		StageBossAttributeName = "StageBoss",
		AutoDestroyLevelGap = 3, -- 플레이어 레벨이 대상보다 이 값 이상 높을 때 몸으로 스쳐도 자동 파괴
		AutoTrampleCooldown = 0.8, -- 애니 지속시간 0.8초
		AutoTrampleDestroyDelay = 0.4, -- 밟기 애니 재생 후 데미지 적용까지(초)
		-- 캐릭터 bbox 기준 자동 밟기 overlap (발 밑·주변 Prop 일괄 수집)
		TrampleBoxScale = 0.7, -- 캐릭터 bbox 대비 수평(X/Z) 배율. Y는 스케일 없이 실측 높이 그대로 사용
		TrampleBoxYOffsetFraction = -0.15, -- bbox 높이 대비 박스 중심 Y (아래로 내릴수록 발 밑 Prop 포함)

		EffectsFolderName = "Effects",

		-- Fever 버튼으로 캐릭터에 붙는 지속 이펙트 (ReplicatedStorage.Effects 하위)
		FeverFxName = "FeverFx",

		-- Fever 버튼 ON 시: 레벨 기준 이동속도·공격 타이밍 배율 (캐릭터 Attribute FeverMode로 동기화)
		FeverMode = {
			MoveSpeedMultiplier = 1.5,
			AttackCooldownMultiplier = 0.5,
			AttackHitDelayMultiplier = 0.5,
			-- 피버 ON 후 자동으로 꺼지기까지 시간(초). 이 동안에는 게이지가 차지 않음(서버).
			DurationSeconds = 10,
		},
		-- 데미지 가능 오브젝트 1개 파괴당 피버 게이지 증가 (0~1, 서버 FeverGaugeHandler)
		FeverGaugePerDestroy = 0.03,

		HitFxName = "HitFx",
		HitFxLifetime = 1,
		HitFxParticleEmitCount = 1,
		HitFxOffset = Vector3.new(0, 0, -0.45),
		-- 클라 HitFxVisibility: 표면 밖 오프셋
		HitFxSurfaceOffset = 0.2,
		-- 카메라~이펙트 최소 거리(studs, scale 비례). 근접 처치/타격 시 레이캐스트가 카메라 코앞
		-- 면에 스냅되면 스케일과 무관하게 원근으로 비정상적으로 커 보이는 문제를 막기 위함.
		HitFxMinCameraDistance = 4,
		-- HitFx ZOffset: Lv1~5 = level×Low, Lv6~9 = level×High
		HitFxZOffsetPerLevelLow = 5,
		HitFxZOffsetPerLevelHigh = 10,
		HitFxZOffsetLevelTierSplit = 5,
		-- (HitFxVisibility fallback 관통 깊이용)
		HitFxZOffsetMargin = 2,
		HitFxZOffsetMarginPerScale = 0.2,
		HitFxZOffsetMax = 40,
		HitFxZOffsetMaxPerScale = 3,
		-- Trample: 스폰 XZ에서 위로 올린 뒤 아래 레이로 지면(terrain/파트) 표면에 배치
		HitFxTrampleGroundRayUpStuds = 50,

		-- 건물 펀치 공격 시 HitFx와 함께 표시(밟기 제외). 대상 건물이 플레이어보다 레벨이 낮으면 표시 안 함.
		JudgementFxName = "JudgementFx",
		JudgementFxParticleName = "judgement",
		JudgementFxLifetime = 1,
		JudgementFxParticleEmitCount = 1,
		JudgementVfxPoolSize = 24,
		-- 대상 건물 레벨(Tier) == 플레이어 레벨
		-- (숫자 리터럴로 두면 15자리 assetId가 tostring()에서 과학적 표기로 깨짐 → 문자열로 보관)
		JudgementFxTextureEqualLevelId = "rbxassetid://79242179182031",
		-- 대상 건물 레벨(Tier) > 플레이어 레벨
		JudgementFxTextureHigherLevelId = "rbxassetid://116995090289354",

		ExplodeEffectName = "ElectricBurst",
		ExplodeEffectLifetime = 2,
		ExplodeParticleEmitCount = 1,
		ExplodeVfxPoolSize = 32,
		HitVfxPoolSize = 24,
		-- 파괴 시 OBB 세로축 방향으로 이 간격(스터드)마다 폭발+데브리스. 0 이하면 기존처럼 중심 1회만
		DestroyEffectVerticalStepStuds = 20,
		-- 위 간격으로 잡히는 층이 너무 많을 때 최대 횟수(초과 시 높이에 균등 분할)
		DestroyEffectMaxVerticalSlices = 40,

		LevelUpEffectName = "LevelUp",
		LevelUpLifetime = 1,
		LevelUpParticleEmitCount = 10,
		LevelUpTextEffectParticleName = "TextEffect",
		-- TextEffect ZOffset = 해당 레벨업 스케일(newScale) + margin
		LevelUpTextEffectZOffsetScaleMargin = 5,

		DebrisPoolSize = 500,
		DebrisCubeCountMin = 10,
		DebrisCubeCountMax = 10,
		DebrisCubeSize = 0.35,
		DebrisLifetimeSeconds = 3,
		DebrisRevealDelaySeconds = 0.2,
		DebrisImpulseMin = 20,
		DebrisImpulseMax = 50,
	},
}

