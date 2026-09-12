local CombatHandler = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")

-- Debris cubes do not collide with players (pass through); still collide with Default (map).
local DEBRIS_COLLISION_GROUP = "TitanStrike_Debris"
local PLAYER_COLLISION_GROUP = "TitanStrike_PlayerBody"
-- Debris cubes also do not collide with enemy NPCs — otherwise a violently-ejected debris cube
-- (from overlap-resolution against still-solid destroyed geometry) can shove an NPC into the
-- player, indirectly transferring that force (enemies stay CollisionGroup="Default" otherwise).
CombatHandler.EnemyCollisionGroup = "TitanStrike_Enemy"
local ENEMY_COLLISION_GROUP = CombatHandler.EnemyCollisionGroup

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameSettings = require(Shared.Config.GameSettings)
local GameManager = require(Shared.Managers.GameManager)
local AttackDamageHelper = require(Shared.Helpers.AttackDamageHelper)
local DamageableObjectStats = require(Shared.Utils.DamageableObjectStats)
local ScaleModule = require(Shared.Utils.ScaleModule)
local ModelWorldExtents = require(Shared.Utils.ModelWorldExtents)
local DebrisPool = require(script.Parent.DebrisPool)
local XpHandler = require(script.Parent.XpHandler)
local FeverGaugeHandler = require(script.Parent.FeverGaugeHandler)
local StageManager = require(script.Parent.StageManager)
local PetManager = require(script.Parent.PetManager)
local SpeechBubbleManager = require(script.Parent.SpeechBubbleManager)
local MissionHelper = require(Shared.Helpers.MissionHelper)
local AchievementHelper = require(Shared.Helpers.AchievementHelper)
local SoundManager = require(Shared.Managers.SoundManager)

local lastAttackTimes: { [number]: number } = {}
local autoTrampleCooldownUntilByUserId: { [number]: number } = {}
local npcKillTracked: { [Model]: boolean } = {}

local function trackNpcKillCredit(enemyModel: Model, player: Player)
	if npcKillTracked[enemyModel] then
		return
	end
	local hum = enemyModel:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end

	npcKillTracked[enemyModel] = true
	hum.Died:Connect(function()
		if player.Parent then
			AchievementHelper.incrementByType(player, "NpcDestroy")
		end
	end)
	enemyModel.Destroying:Connect(function()
		npcKillTracked[enemyModel] = nil
	end)
end
local attackCooldownUntilByUserId: { [number]: number } = {}

local TRAMPLE_PENDING_ATTRIBUTE = "TramplePending"

--- 유물 AttackSpeedUp 옵션 % 만큼 쿨다운/딜레이를 줄이는 배율 (Attribute는 onPlayerAdded에서 1회 캐시됨)
local function getAttackSpeedUpMultiplier(player: Player): number
	local percent = player:GetAttribute("AttackSpeedUpPercent")
	if typeof(percent) ~= "number" or percent <= 0 then
		return 1
	end
	return 1 / (1 + percent / 100)
end

local function getAttackCooldownForPlayer(player: Player): number
	local base = GameSettings.Combat.AttackCooldown
	local feverMult = 1
	local ch = player.Character
	if ch and ch:GetAttribute("FeverMode") == true then
		local fm = GameSettings.Combat.FeverMode
		if typeof(fm) == "table" then
			local m = fm.AttackCooldownMultiplier
			if typeof(m) == "number" and m == m and m > 0 then
				feverMult = m
			end
		end
	end
	return base * feverMult * getAttackSpeedUpMultiplier(player)
end

local function getAutoTrampleCooldownForPlayer(player: Player): number
	local base = GameSettings.Combat.AutoTrampleCooldown or 0.8
	local feverMult = 1
	local ch = player.Character
	if ch and ch:GetAttribute("FeverMode") == true then
		local fm = GameSettings.Combat.FeverMode
		if typeof(fm) == "table" then
			local m = fm.AttackCooldownMultiplier
			if typeof(m) == "number" and m == m and m > 0 then
				feverMult = m
			end
		end
	end
	return base * feverMult * getAttackSpeedUpMultiplier(player)
end

local function getAutoTrampleDestroyDelayForPlayer(player: Player): number
	local base = GameSettings.Combat.AutoTrampleDestroyDelay or 0.4
	local feverMult = 1
	local ch = player.Character
	if ch and ch:GetAttribute("FeverMode") == true then
		local fm = GameSettings.Combat.FeverMode
		if typeof(fm) == "table" then
			local m = fm.AttackHitDelayMultiplier
			if typeof(m) == "number" and m == m and m > 0 then
				feverMult = m
			end
		end
	end
	return base * feverMult * getAttackSpeedUpMultiplier(player)
end

local function isPlayerInAutoTrampleCooldown(userId: number, now: number): boolean
	local untilTs = autoTrampleCooldownUntilByUserId[userId]
	return untilTs ~= nil and untilTs > now
end

local function isPlayerInAttackCooldown(player: Player, now: number): boolean
	local untilTs = attackCooldownUntilByUserId[player.UserId]
	return untilTs ~= nil and untilTs > now
end

local function isPlayerInFeverIntroLock(player: Player): boolean
	local ch = player.Character
	return ch ~= nil and ch:GetAttribute("FeverIntroLocked") == true
end

local function tierOnModel(model: Model): number?
	return DamageableObjectStats.tierOnModel(model)
end

local function currentHitPointOnModel(model: Model): number?
	return DamageableObjectStats.currentHitPointOnModel(model)
end

local function getDamageableModelFromPart(part: BasePart): Model?
	local inst: Instance? = part
	while inst and inst ~= Workspace do
		if inst:IsA("Model") then
			local hp = currentHitPointOnModel(inst)
			if hp ~= nil and hp > 0 then
				return inst
			end
		end
		inst = inst.Parent
	end
	return nil
end

--- HitPoint config 오브젝트가 아닌 NPC(플레이어 캐릭터 제외) Humanoid 모델
local function getEnemyNpcModelFromPart(part: BasePart): Model?
	local inst: Instance? = part
	while inst and inst ~= Workspace do
		if inst:IsA("Model") then
			local hum = inst:FindFirstChildOfClass("Humanoid")
			if hum and Players:GetPlayerFromCharacter(inst) == nil and not DamageableObjectStats.hasDamageableConfig(inst) then
				return inst
			end
		end
		inst = inst.Parent
	end
	return nil
end

local function getCharacterLevel(character: Model): number
	local level = character:GetAttribute("XPLevel")
	if typeof(level) == "number" and level == level and level >= 1 then
		return math.floor(level + 0.5)
	end
	return 1
end

-- Client plays VFX; server-only clones often fail to show for marketplace assets.
local function playExplodeEffectAt(worldPosition: Vector3, effectScale: number, playDestroySfx: boolean?, targetModel: Model?)
	local ev = ReplicatedStorage:FindFirstChild("ExplodeVfxEvent")
	if ev and ev:IsA("RemoteEvent") then
		ev:FireAllClients(worldPosition, effectScale, playDestroySfx == true, targetModel)
	end
end

local function spawnDestructDebrisCubes(worldPosition: Vector3, objectLevel: number, countBudgetScale: number?)
	local c = GameSettings.Combat
	local minC = c.DebrisCubeCountMin or 20
	local maxC = c.DebrisCubeCountMax or 20
	if maxC < minC then
		maxC = minC
	end
	local budget = 1
	if typeof(countBudgetScale) == "number" and countBudgetScale == countBudgetScale and countBudgetScale > 0 then
		budget = countBudgetScale
	end
	local mult = math.max(1, objectLevel)
	-- 레벨 1 기준, 레벨마다 약 +15% (큐브 개수·임펄스 공통 배율)
	local levelScale = 1 + 0.15 * (mult - 1)
	local count = math.max(1, math.floor(math.random(minC, maxC) * levelScale * budget + 0.5))
	local baseSize = c.DebrisCubeSize or 0.35
	local size = baseSize * mult
	local lifetime = c.DebrisLifetimeSeconds or 3
	local vmin = c.DebrisImpulseMin or 42
	local vmax = c.DebrisImpulseMax or 96
	local revealDelay = math.max(0, c.DebrisRevealDelaySeconds or 0.2)

	local spread = 0.45
	local half = size * 0.5
	-- L1 클러스터에 대응하는 기준 반경; mult>1이면 구 반지름 = 이 값 × mult (겹침·임펄스 상쇄 완화)
	local debrisSpawnRadiusL1 = spread * 0.5 + baseSize * 0.5 + 0.25

	local function randomUnitVector(): Vector3
		while true do
			local v = Vector3.new(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1)
			if v.Magnitude > 0.05 then
				return v.Unit
			end
		end
	end

	--- 구 볼륨에 균등: 반지름 r = R * u^(1/3), 방향은 구면 균등
	local function randomOffsetInBall(radius: number): Vector3
		if radius <= 1e-4 then
			return Vector3.zero
		end
		return randomUnitVector() * (radius * (math.random() ^ (1 / 3)))
	end

	for i = 1, count do
		local p = DebrisPool.acquire()
		if not p then
			warn("[CombatHandler] DebrisPool.acquire failed; skipped", count - i + 1, "cube(s) this burst")
			break
		end

		p.Size = Vector3.new(size, size, size)

		p.Color = Color3.fromHSV(((i * 0.09 + math.random() * 0.15) % 1), 0.55, 0.9)
		-- Invisible until DebrisRevealDelaySeconds after ApplyImpulse (physics runs invisibly first)
		p.Transparency = 1
		p.CanCollide = true

		local spawnPos: Vector3
		if mult > 1 then
			spawnPos = worldPosition + randomOffsetInBall(debrisSpawnRadiusL1 * mult)
		else
			spawnPos = worldPosition
				+ Vector3.new((math.random() - 0.5) * spread, half + 0.2 + math.random() * 0.15, (math.random() - 0.5) * spread)
		end

		local dir = Vector3.new(math.random() * 2 - 1, math.random() * 0.5 + 0.25, math.random() * 2 - 1)
		if dir.Magnitude < 0.05 then
			dir = Vector3.new(0, 1, 0)
		else
			dir = dir.Unit
		end

		local speed = (vmin + math.random() * (vmax - vmin)) * levelScale

		local spin = Vector3.new(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1)
		if spin.Magnitude < 0.05 then
			spin = Vector3.new(0, 1, 0)
		else
			spin = spin.Unit
		end
		local angCoeff = (5 + math.random() * 10) * levelScale

		p.Anchored = true
		p.CFrame = CFrame.new(spawnPos) * CFrame.Angles(math.random() * math.pi * 2, math.random() * math.pi * 2, math.random() * math.pi * 2)
		p.Parent = Workspace
		p.Anchored = false

		p:ApplyImpulse(dir * speed * p.AssemblyMass)
		p:ApplyAngularImpulse(spin * angCoeff * p.AssemblyMass)

		local cube = p
		task.delay(revealDelay, function()
			if cube.Parent == Workspace then
				cube.Transparency = 0
			end
		end)

		task.delay(revealDelay + lifetime, function()
			DebrisPool.release(cube)
		end)
	end
end

--- OBB의 세로축( size.Y )을 따라 step 스터드마다 월드 위치(바닥→위). step≤0 이면 중심 1개만
--- (폴백 경로: computeVisible이 보이는 파츠를 찾지 못했을 때 사용)
local function getDestroyEffectSlicePositionsFromBoundingBox(model: Model): { Vector3 }
	local ok, cf, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if not ok or typeof(cf) ~= "CFrame" or typeof(size) ~= "Vector3" then
		return { model:GetPivot().Position }
	end

	local c = GameSettings.Combat
	local step = c.DestroyEffectVerticalStepStuds
	if typeof(step) ~= "number" or step ~= step or step <= 0 then
		return { cf.Position }
	end

	local height = size.Y
	if height <= step then
		return { cf.Position }
	end

	local up = cf.UpVector
	local bottom = cf.Position - up * (height * 0.5)

	local maxSlices = c.DestroyEffectMaxVerticalSlices
	if typeof(maxSlices) ~= "number" or maxSlices < 1 then
		maxSlices = 40
	end

	local nByStep = math.floor(height / step)
	if nByStep < 1 then
		return { cf.Position }
	end

	local positions: { Vector3 } = {}

	if nByStep <= maxSlices then
		for i = 1, nByStep do
			local d = i * step
			if d > height + 1e-4 then
				break
			end
			table.insert(positions, bottom + up * d)
		end
	else
		local n = maxSlices
		local span = height / (n + 1)
		for i = 1, n do
			table.insert(positions, bottom + up * (i * span))
		end
	end

	if #positions == 0 then
		return { cf.Position }
	end
	return positions
end

--- 보이는 파츠(Transparency<1) 기준 월드축 세로 범위를 step 스터드마다 슬라이스(바닥→위).
--- 공격판정용으로 세로로 크게 만든 투명 파츠가 섞여 있어도 실제 렌더링 영역 기준으로 계산된다.
--- 보이는 파츠가 없으면(전부 투명 등) 기존 OBB 기반 로직으로 폴백.
local function getDestroyEffectSlicePositions(model: Model): { Vector3 }
	local visible = ModelWorldExtents.computeVisible(model)
	if not visible or visible.sizeY <= 0 then
		return getDestroyEffectSlicePositionsFromBoundingBox(model)
	end

	local c = GameSettings.Combat
	local step = c.DestroyEffectVerticalStepStuds

	local function centerPos(): Vector3
		return Vector3.new(visible.centerX, visible.topY - visible.sizeY * 0.5, visible.centerZ)
	end

	if typeof(step) ~= "number" or step ~= step or step <= 0 then
		return { centerPos() }
	end

	local height = visible.sizeY
	if height <= step then
		return { centerPos() }
	end

	local bottomY = visible.topY - height

	local maxSlices = c.DestroyEffectMaxVerticalSlices
	if typeof(maxSlices) ~= "number" or maxSlices < 1 then
		maxSlices = 40
	end

	local nByStep = math.floor(height / step)
	if nByStep < 1 then
		return { centerPos() }
	end

	local positions: { Vector3 } = {}

	if nByStep <= maxSlices then
		for i = 1, nByStep do
			local d = i * step
			if d > height + 1e-4 then
				break
			end
			table.insert(positions, Vector3.new(visible.centerX, bottomY + d, visible.centerZ))
		end
	else
		local n = maxSlices
		local span = height / (n + 1)
		for i = 1, n do
			table.insert(positions, Vector3.new(visible.centerX, bottomY + i * span, visible.centerZ))
		end
	end

	if #positions == 0 then
		return getDestroyEffectSlicePositionsFromBoundingBox(model)
	end
	return positions
end

local function isStageBossModel(model: Model): boolean
	local name = GameSettings.Combat.StageBossAttributeName or "StageBoss"
	return model:GetAttribute(name) == true
end

--- 건물 파츠가 CanCollide=true인 채로 남아있으면, 그 안에 파묻힌 채 스폰되는 디브리 큐브가
--- unanchor+임펄스 시점에 겹침을 풀어내며 과도한 속도를 얻을 수 있다(플레이어 승천 버그의 한 원인).
--- 어차피 이 함수 끝에서 model:Destroy()가 호출되므로 미리 꺼도 체감되는 변화는 없다.
local function disableModelCollision(model: Model)
	for _, inst in model:GetDescendants() do
		if inst:IsA("BasePart") then
			inst.CanCollide = false
		end
	end
end

local function destroyDamageableModel(
	player: Player,
	model: Model,
	objectTier: number,
	attackKind: string?,
	isPetAttack: boolean?
): boolean
	if not model.Parent then
		return false
	end

	local triggerStageClear = isStageBossModel(model)

	local positions = getDestroyEffectSlicePositions(model)
	disableModelCollision(model)
	local effectScale = math.max(1, objectTier)
	local sliceCount = #positions
	local debrisBudget = 1 / sliceCount

	local hitFxEv = ReplicatedStorage:FindFirstChild("HitFxEvent")
	local character = player.Character
	local characterScale = GameSettings.Scale.PlayerScale
	local playerLevel = 1
	if character then
		characterScale = ScaleModule.getCharacterScale(character)
		playerLevel = getCharacterLevel(character)
	end

	for index, pos in positions do
		playExplodeEffectAt(pos, effectScale, index == 1, model)
		if hitFxEv and hitFxEv:IsA("RemoteEvent") then
			hitFxEv:FireAllClients(
				CFrame.new(pos),
				characterScale,
				SoundManager.HitFxKind.Destroy,
				model,
				playerLevel
			)
		end
		spawnDestructDebrisCubes(pos, objectTier, debrisBudget)
	end
	print("[CombatHandler]", player.Name, "destroyed", model.Name)
	local grantedXp, xpGapMult, rawXp, xpTargetTier = XpHandler.grantXpFromDestroy(player, model)
	if RunService:IsStudio() and not isPetAttack and grantedXp then
		print(
			string.format(
				"[CombatHandler][DEBUG] xp %s (Tier %d) rawXp=%d gapMult=x%.3f xp=%d",
				model.Name,
				xpTargetTier :: number,
				rawXp :: number,
				xpGapMult :: number,
				grantedXp
			)
		)
	end
	FeverGaugeHandler.addDestroyProgress(player)
	if not triggerStageClear then
		MissionHelper.incrementProgress(player, 2)
		if attackKind == "Punch" then
			MissionHelper.incrementProgress(player, 4)
		elseif attackKind == "Trample" then
			MissionHelper.incrementProgress(player, 5)
		end
		AchievementHelper.incrementByType(player, "PropDestroy")
		AchievementHelper.incrementByType(player, "TargetPropDestroy", {
			targetKey = model.Name,
		})
	end
	if triggerStageClear then
		StageManager.clearStage()
	end
	PetManager.onBuildingDestroyed(player, model)
	SpeechBubbleManager.onBuildingClaimed(player, model)
	model:Destroy()
	return true
end

--- 공격·밟기 공통: 어택 데미지 1회 적용. HP 0 이하면 파괴.
--- isPetAttack이 true면 펫이 때린 경우(디버그 로그는 플레이어 본인 공격만 남긴다).
local function applyAttackDamageToDamageableModel(
	player: Player,
	model: Model,
	playerLevel: number,
	baseAttackDamage: number,
	isPetAttack: boolean?,
	attackKind: string?
): (boolean, boolean)
	if not model.Parent then
		return false, false
	end

	local hp = currentHitPointOnModel(model)
	if not hp or hp <= 0 then
		return false, false
	end

	local currentHpAttr = GameSettings.Combat.CurrentHitPointAttributeName or "CurrentHitPoint"
	local targetTier = tierOnModel(model) or 1
	local gapMult = AttackDamageHelper.getLevelGapDamageMultiplier(playerLevel, targetTier)
	local attackDamage = math.max(1, math.floor(baseAttackDamage * gapMult + 0.5))
	local nextHp = math.max(0, hp - attackDamage)
	model:SetAttribute(currentHpAttr, nextHp)

	if RunService:IsStudio() and not isPetAttack then
		print(
			string.format(
				"[CombatHandler][DEBUG] hit %s (Tier %d) damageByLevel=%d gapMult=x%.3f dmg=%d",
				model.Name,
				targetTier,
				baseAttackDamage,
				gapMult,
				attackDamage
			)
		)
	end

	if hp - attackDamage <= 0 then
		return destroyDamageableModel(player, model, targetTier, attackKind, isPetAttack), true
	end
	return false, true
end

local function getAttackerMaxHeadY(character: Model?): number?
	if not character then
		return nil
	end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position.Y + head.Size.Y * 0.5
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.Position.Y + hrp.Size.Y * 0.5
	end
	return nil
end

--- hitCf는 파괴로 model이 이미 Destroy된 뒤에도 쓸 수 있도록 호출부에서 미리 캡처해 전달한다.
local function fireAttackHitFxForTarget(
	player: Player,
	hitFxEv: RemoteEvent,
	targetModel: Model,
	hitCf: CFrame,
	scale: number,
	playerLevel: number
)
	local maxHeadY = getAttackerMaxHeadY(player.Character)
	hitFxEv:FireAllClients(hitCf, scale, SoundManager.HitFxKind.Attack, targetModel, playerLevel, maxHeadY)
end

--- 건물 펀치 공격 HitFx와 함께 표시되는 심판(Judgement) 이펙트. 파괴되는 한 방이어도 표시되도록
--- hitCf/targetTier는 호출부에서 파괴 전에 미리 캡처해 전달한다.
--- 대상 건물이 플레이어보다 레벨이 낮으면 표시하지 않음; 같으면 "Equal", 높으면 "Higher" 텍스처.
local function fireAttackJudgementFxForTarget(
	player: Player,
	judgementFxEv: RemoteEvent,
	targetModel: Model,
	hitCf: CFrame,
	scale: number,
	targetTier: number,
	playerLevel: number
)
	if targetTier < playerLevel then
		return
	end
	local kind = targetTier == playerLevel and "Equal" or "Higher"
	local maxHeadY = getAttackerMaxHeadY(player.Character)
	judgementFxEv:FireAllClients(hitCf, scale, targetModel, kind, maxHeadY)
end

--- 클라이언트가 보낸 히트박스 중심이 실제로 그 플레이어 손이 닿을 수 있는 범위인지 검증.
--- (조작된 클라이언트가 맵 아무 곳이나 히트박스 좌표를 보내 원거리 파괴하는 것을 막음)
--- 서버가 받는 HRP 위치는 리플리케이션 지연으로 클라이언트가 공격한 순간보다 뒤처질 수 있어,
--- WalkSpeed 기준으로 그 사이 이동 가능했던 거리만큼 여유를 둔다 (그러지 않으면 이동 중 공격이 오탐됨).
local ATTACK_REACH_BASE_SLOP_STUDS = 6
local ATTACK_REACH_SPEED_SLOP_SECONDS = 0.5

local function isHitboxWithinReach(character: Model, clientHitboxCenter: CFrame, scale: number): boolean
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return false
	end

	local range = GameSettings.Combat.AttackRange * scale
	local offset = GameSettings.Combat.AttackOffset

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local moveSpeed = (humanoid and humanoid.WalkSpeed) or 16
	local movementSlop = ATTACK_REACH_BASE_SLOP_STUDS + moveSpeed * ATTACK_REACH_SPEED_SLOP_SECONDS

	local maxReach = offset.Magnitude + range / 2 + movementSlop
	local dist = (clientHitboxCenter.Position - hrp.Position).Magnitude
	return dist <= maxReach
end

local function performAttackHit(player: Player, clientHitboxCenter: CFrame, scale: number)
	if GameManager.State.CurrentPhase == "Ended" then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	if not isHitboxWithinReach(character, clientHitboxCenter, scale) then
		return
	end

	local range = GameSettings.Combat.AttackRange * scale
	local boxScale = GameSettings.Combat.AttackBoxScale or Vector3.new(1, 1, 1)

	local boxCenter = clientHitboxCenter
	local boxSize = Vector3.new(range, range, range) * boxScale

	local overlapParams = OverlapParams.new()
	overlapParams.FilterDescendantsInstances = { character }
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude

	local hitParts = workspace:GetPartBoundsInBox(boxCenter, boxSize, overlapParams)

	local damageableModels: { [Model]: boolean } = {}
	local enemyModels: { [Model]: boolean } = {}
	for _, part in hitParts do
		if part:IsA("BasePart") then
			local m = getDamageableModelFromPart(part)
			if m then
				damageableModels[m] = true
			end
			local em = getEnemyNpcModelFromPart(part)
			if em then
				enemyModels[em] = true
			end
		end
	end

	local playerLevel = getCharacterLevel(character)
	local baseAttackDamage = AttackDamageHelper.getAttackDamageForLevel(playerLevel)
	local hitFxEv = ReplicatedStorage:FindFirstChild("HitFxEvent")
	local judgementFxEv = ReplicatedStorage:FindFirstChild("JudgementFxEvent")

	for model, _ in pairs(enemyModels) do
		if model.Parent then
			local hum = model:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				trackNpcKillCredit(model, player)
				-- 스폰 적은 레벨이 없으므로 플레이어 기본 공격력 100% (갭 배율 미적용)
				local attackDamage = math.max(1, baseAttackDamage)
				hum:TakeDamage(attackDamage)
				if hitFxEv and hitFxEv:IsA("RemoteEvent") then
					fireAttackHitFxForTarget(player, hitFxEv, model, model:GetBoundingBox(), scale, playerLevel)
				end
			end
		end
	end
	local hitDamageableModels: { Model } = {}
	for model, _ in pairs(damageableModels) do
		table.insert(hitDamageableModels, model)
	end

	for _, model in hitDamageableModels do
		-- 파괴되는 한 방이면 model이 destroy되어 버리므로, 공격 판정 시점 위치·Tier를 미리 캡처해둔다.
		local hitCf = model:GetBoundingBox()
		local targetTier = tierOnModel(model) or 1
		local _destroyed, damaged =
			applyAttackDamageToDamageableModel(player, model, playerLevel, baseAttackDamage, nil, "Punch")
		if damaged then
			if hitFxEv and hitFxEv:IsA("RemoteEvent") then
				fireAttackHitFxForTarget(player, hitFxEv, model, hitCf, scale, playerLevel)
			end
			if judgementFxEv and judgementFxEv:IsA("RemoteEvent") then
				fireAttackJudgementFxForTarget(player, judgementFxEv, model, hitCf, scale, targetTier, playerLevel)
			end
		end
	end
end

local function setupDebrisPlayerCollisionGroups()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(DEBRIS_COLLISION_GROUP)
	end)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(PLAYER_COLLISION_GROUP)
	end)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(ENEMY_COLLISION_GROUP)
	end)
	PhysicsService:CollisionGroupSetCollidable(DEBRIS_COLLISION_GROUP, PLAYER_COLLISION_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(DEBRIS_COLLISION_GROUP, ENEMY_COLLISION_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(DEBRIS_COLLISION_GROUP, "Default", true)
	-- ?뚰렪?쇰━??遺?ろ엳吏 ?딆쓬(???먯뿉 ?볦씠硫?萸됯컻吏???꾩긽 ?꾪솕). 諛붾떏(Default)? 洹몃?濡?異⑸룎
	PhysicsService:CollisionGroupSetCollidable(DEBRIS_COLLISION_GROUP, DEBRIS_COLLISION_GROUP, false)
end

local function qualifiesForAutoTrample(playerLevel: number, model: Model): boolean
	local targetTier = tierOnModel(model)
	if not targetTier then
		return false
	end
	local autoDestroyGap = GameSettings.Combat.AutoDestroyLevelGap or 3
	return playerLevel - targetTier >= autoDestroyGap
end

local function getTrampleOverlapBox(character: Model): (CFrame, Vector3)
	local cf, size = character:GetBoundingBox()
	local combat = GameSettings.Combat
	local boxScale = combat.TrampleBoxScale
	local yFrac = combat.TrampleBoxYOffsetFraction
	if typeof(yFrac) ~= "number" then
		yFrac = -0.15
	end
	local boxSize = Vector3.new(size.X * boxScale, size.Y, size.Z * boxScale)
	local boxCenter = cf * CFrame.new(0, size.Y * yFrac, 0)
	return boxCenter, boxSize
end

local function collectAutoTrampleTargets(character: Model, playerLevel: number): { Model }
	local boxCenter, boxSize = getTrampleOverlapBox(character)

	local overlapParams = OverlapParams.new()
	overlapParams.FilterDescendantsInstances = { character }
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude

	local targets: { Model } = {}
	local seen: { [Model]: boolean } = {}

	for _, part in Workspace:GetPartBoundsInBox(boxCenter, boxSize, overlapParams) do
		if part:IsA("BasePart") then
			local damageableModel = getDamageableModelFromPart(part)
			if damageableModel and not seen[damageableModel] then
				if damageableModel:GetAttribute(TRAMPLE_PENDING_ATTRIBUTE) ~= true
					and qualifiesForAutoTrample(playerLevel, damageableModel) then
					seen[damageableModel] = true
					table.insert(targets, damageableModel)
				end
			end
		end
	end

	return targets
end

local function clearTramplePendingOnTargets(targets: { Model })
	for _, targetModel in targets do
		if targetModel.Parent then
			targetModel:SetAttribute(TRAMPLE_PENDING_ATTRIBUTE, nil)
		end
	end
end

local function applyTrampleHitToTargets(player: Player, targets: { Model }, playerLevel: number)
	local baseAttackDamage = AttackDamageHelper.getAttackDamageForLevel(playerLevel)
	local hitFxEv = ReplicatedStorage:FindFirstChild("HitFxEvent")

	local characterScale = GameSettings.Scale.PlayerScale
	local character = player.Character
	if character then
		characterScale = ScaleModule.getCharacterScale(character)
	end

	for _, targetModel in targets do
		if not targetModel.Parent then
			continue
		end

		targetModel:SetAttribute(TRAMPLE_PENDING_ATTRIBUTE, nil)

		local destroyed, damaged =
			applyAttackDamageToDamageableModel(player, targetModel, playerLevel, baseAttackDamage, nil, "Trample")
		if not destroyed and damaged and hitFxEv and hitFxEv:IsA("RemoteEvent") then
			local hitCf = targetModel:GetBoundingBox()
			hitFxEv:FireAllClients(hitCf, characterScale, SoundManager.HitFxKind.Trample, targetModel, playerLevel)
		end
	end
end

local function assignPlayerBodyCollisionGroup(player: Player, character: Model)
	local function applyPart(inst: Instance)
		if inst:IsA("BasePart") then
			inst.CollisionGroup = PLAYER_COLLISION_GROUP
			inst.Touched:Connect(function(otherPart: BasePart)
				if GameManager.State.CurrentPhase == "Ended" then
					return
				end

				local model = getDamageableModelFromPart(otherPart)
				if not model or not model.Parent then
					return
				end
				if model:GetAttribute(TRAMPLE_PENDING_ATTRIBUTE) == true then
					return
				end

				local playerLevel = getCharacterLevel(character)
				if not qualifiesForAutoTrample(playerLevel, model) then
					return
				end

				local now = tick()
				local userId = player.UserId
				if isPlayerInAutoTrampleCooldown(userId, now) then
					return
				end
				if isPlayerInAttackCooldown(player, now) then
					return
				end
				if isPlayerInFeverIntroLock(player) then
					return
				end

				local trampleTargets = collectAutoTrampleTargets(character, playerLevel)
				if #trampleTargets == 0 then
					return
				end

				autoTrampleCooldownUntilByUserId[userId] = now + getAutoTrampleCooldownForPlayer(player)

				local destroyDelay = getAutoTrampleDestroyDelayForPlayer(player)

				for _, targetModel in trampleTargets do
					targetModel:SetAttribute(TRAMPLE_PENDING_ATTRIBUTE, true)
				end

				local trampleAnimEv = ReplicatedStorage:FindFirstChild("TrampleAnimEvent")
				if trampleAnimEv and trampleAnimEv:IsA("RemoteEvent") then
					trampleAnimEv:FireAllClients(player)
				end

				task.delay(destroyDelay, function()
					if GameManager.State.CurrentPhase == "Ended" then
						clearTramplePendingOnTargets(trampleTargets)
						return
					end
					if not character.Parent then
						clearTramplePendingOnTargets(trampleTargets)
						return
					end

					applyTrampleHitToTargets(player, trampleTargets, playerLevel)
				end)
			end)
		end
	end
	for _, d in character:GetDescendants() do
		applyPart(d)
	end
	character.DescendantAdded:Connect(applyPart)
end

local function wirePlayerForDebrisCollision(player: Player)
	player.CharacterAdded:Connect(function(character)
		assignPlayerBodyCollisionGroup(player, character)
	end)
	if player.Character then
		assignPlayerBodyCollisionGroup(player, player.Character)
	end
end

function CombatHandler.init()
	print("[CombatHandler] init")

	setupDebrisPlayerCollisionGroups()

	local combatCfg = GameSettings.Combat
	DebrisPool.init(
		combatCfg.DebrisPoolSize or 500,
		combatCfg.DebrisCubeSize or 0.35,
		DEBRIS_COLLISION_GROUP,
		PhysicalProperties.new(0.9, 0.42, 0.25)
	)

	Players.PlayerAdded:Connect(wirePlayerForDebrisCollision)
	for _, plr in Players:GetPlayers() do
		wirePlayerForDebrisCollision(plr)
	end

	local function ensureRemoteEvent(name: string): RemoteEvent
		local existing = ReplicatedStorage:FindFirstChild(name)
		if existing and existing:IsA("RemoteEvent") then
			return existing
		end
		local ev = Instance.new("RemoteEvent")
		ev.Name = name
		ev.Parent = ReplicatedStorage
		return ev
	end

	ensureRemoteEvent("ExplodeVfxEvent")
	local attackEvent = ensureRemoteEvent("AttackEvent")
	ensureRemoteEvent("HitFxEvent")
	ensureRemoteEvent("JudgementFxEvent")
	ensureRemoteEvent("TrampleAnimEvent")
	local registerAttackCooldownEvent = ensureRemoteEvent("RegisterAttackCooldown")

	registerAttackCooldownEvent.OnServerEvent:Connect(function(player: Player)
		if GameManager.State.CurrentPhase == "Ended" then
			return
		end
		local now = tick()
		if isPlayerInAutoTrampleCooldown(player.UserId, now) then
			return
		end
		if isPlayerInFeverIntroLock(player) then
			return
		end
		attackCooldownUntilByUserId[player.UserId] = now + getAttackCooldownForPlayer(player)
	end)

	attackEvent.OnServerEvent:Connect(function(player: Player, clientHitboxCenter: CFrame, scale: number)
		if GameManager.State.CurrentPhase == "Ended" then
			return
		end

		local now = tick()
		local userId = player.UserId

		if now - (lastAttackTimes[userId] or 0) < getAttackCooldownForPlayer(player) then
			return
		end
		if isPlayerInAutoTrampleCooldown(userId, now) then
			return
		end
		if isPlayerInFeverIntroLock(player) then
			return
		end

		lastAttackTimes[userId] = now

		if typeof(clientHitboxCenter) ~= "CFrame" or typeof(scale) ~= "number" then
			return
		end

		scale = math.clamp(scale, GameSettings.Scale.MinScale, GameSettings.Scale.MaxScale)
		performAttackHit(player, clientHitboxCenter, scale)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastAttackTimes[player.UserId] = nil
		autoTrampleCooldownUntilByUserId[player.UserId] = nil
		attackCooldownUntilByUserId[player.UserId] = nil
	end)

	print("[CombatHandler] init done")
end

return CombatHandler

