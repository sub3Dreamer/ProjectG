--[[
	건물(Model) 파괴 시, 그 건물에 SpeechBubbleGui가 있었다면(SpeechBubbleManager가 배치한 대상)
	PetData의 펫을 ServerStorage.Pet.<modelName>에서 클론해 파괴한 플레이어의 캐릭터 자식으로 배치하고,
	플레이어를 뒤따르도록 대열(포메이션)로 위치를 갱신한다.

	CombatHandler.destroyDamageableModel()에서 model:Destroy() 전에 PetManager.onBuildingDestroyed()를 호출한다.

	포메이션: 플레이어 뒤쪽에 최대 ROW_WIDTH(5)개씩 행을 채우며, 각 행은 오른쪽부터 ROW_FILL_ORDER 순서로 채운다.
	11마리째부터는 새 행이 동일 규칙으로 다시 오른쪽부터 채워지므로 마리 수 제한 없이 계속 확장된다.
	CELL_STUDS/ROW_GAP_STUDS/ODD_COL_BACK_STUDS/FRONT_GAP_STUDS는 하한선일 뿐이고, 실제 간격은
	computeFormationSpacing()이 보유 펫들의 실측 가로/세로(ModelWorldExtents, Model.Scale 반영)
	중 가장 큰 값 기준으로 자동으로 넓힌다. ROW_FILL_ORDER는 참고 이미지를 기반으로 한 1차 추정치이므로,
	실제 게임 내 비주얼을 보고 조정 필요.

	펫 애니메이션: 각 펫 템플릿에 독립 Script를 두지 않고, 이 모듈이 매 Heartbeat마다
	모든 펫 공용 클록(animStartTime 기준 elapsed)으로 PetAnimationRegistry의 상태별 핸들러를
	호출한다. 실제 관절 수식은 펫 종류별 모듈(예: pets/animations/GoldenPiggyBank.luau)에 있고,
	여기서는 언제(타이밍)·어떤 상태(state)로 호출할지만 관리한다.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MotorJointAnimator = require(Shared.Utils.MotorJointAnimator)
local ScaleModule = require(Shared.Utils.ScaleModule)
local ModelWorldExtents = require(Shared.Utils.ModelWorldExtents)
local CharacterScaleCurve = require(Shared.Config.CharacterScaleCurve)
local GameSettings = require(Shared.Config.GameSettings)
local MissionHelper = require(Shared.Helpers.MissionHelper)
local PetAnimationRegistry = require(script.Parent.pets.PetAnimationRegistry)
local XpHandler = require(script.Parent.XpHandler)

local PetManager = {}

local initialized = false

local PET_DATA_MODULE_NAME = "PetData"
local PET_TEMPLATES_FOLDER_NAME = "Pet"
local DEFAULT_PET_ID = "Pet_01"
local LEGACY_IDLE_SCRIPT_NAME = "IdleAnimationScript" -- 마이그레이션 이전 템플릿에 남아있을 수 있는 구 스크립트

--- 일부 펫 모델은 리그 자체의 정면 방향이 Roblox 기본 전방(Orientation 0 = -Z 정면)과 어긋나 있어,
--- PivotTo 직전에 모델 로컬 공간에서 이만큼(도 단위 Y축) 추가로 돌려줘야 실제 이동 방향을 보고 서게 된다.
--- Ghost Dragon(Pet_07)/Mystic Flower(Pet_08)는 리그 상 OrientationY -180이 정면이라 보정 필요.
local PET_FORWARD_ORIENTATION_OFFSET_DEGREES: { [string]: number } = {
	Pet_07 = -180,
	Pet_08 = -180,
}

local ROW_WIDTH = 5
local ROW_FILL_ORDER = { 4, 2, 3, 5, 1 } -- 행 내 열(1~ROW_WIDTH) 채우는 순서: 안쪽(오른쪽/왼쪽) → 중앙 → 바깥쪽(오른쪽/왼쪽)
-- 아래 4개는 "최소값"이다. 실제 간격은 그 플레이어가 보유한 펫들의 실측 가로/세로(ModelWorldExtents,
-- Model.Scale이 반영된 월드 축 정렬 크기)에 맞춰 이보다 넓게 자동으로 늘어난다 — 펫이 커지면(예: Scale
-- 0.2→0.3) 겹치지 않도록. 아주 작은 펫에서도 대형이 너무 촘촘해 보이지 않도록 하한선 역할만 한다.
local CELL_STUDS = 2.5 -- 같은 행 내 열 간 간격의 최소값
local ROW_GAP_STUDS = 2.5 -- 행과 행 사이 간격의 최소값
local FRONT_GAP_STUDS = 3 -- 플레이어와 첫 행 사이 거리의 최소값(플레이어 Scale 배율 적용 전 기준)
local ODD_COL_BACK_STUDS = 0.8 -- 지그재그 오프셋의 최소값(같은 행에서 홀수 열(1,3,5)이 짝수 열(2,4)보다 살짝 더 뒤로 빠지는 정도)
local CELL_PADDING_STUDS = 0.5 -- 펫 실측 가로 폭에 더해지는 여백(열 간격 계산용)
local ROW_GAP_PADDING_RATIO = 0.25 -- 펫 실측 가로 폭의 이 비율만큼 행 간격에 여백으로 더함(고정 스터드 대신 가로 폭에 비례)
local FRONT_GAP_PADDING_STUDS = 1 -- 펫 실측 세로 깊이의 절반에 더해지는 여백(첫 행 거리 계산용)
local ODD_COL_BACK_RATIO = 0.5 -- 지그재그 오프셋 = 펫 실측 가로 폭 * 이 비율
local FOLLOW_SMOOTH_TIME_SEC = 0.25 -- 목표 지점까지 도달하는 데 걸리는 대략적인 시간(가속도 기반 SmoothDamp). 클수록 관성이 강하고 느리게 따라옴
local FOLLOW_MAX_SPEED_STUDS = 40 -- SmoothDamp 속도 상한(스터드/초)의 최소값. 목표가 갑자기 멀리 튈 때 순간 가속 폭주 방지
local FOLLOW_MAX_SPEED_PLAYER_MULTIPLIER = 1.5 -- 실제 상한 = max(FOLLOW_MAX_SPEED_STUDS, 플레이어 현재 WalkSpeed * 이 배율). 레벨업으로 플레이어가 빨라져도(ScaleModule의 calculateWalkSpeed) 펫이 뒤처지지 않도록 플레이어 속도에 연동
local MAX_PETS_PER_PLAYER = 20 -- 플레이어당 최대 펫 보유 개수. 초과분은 지급하지 않음
local MOVE_STATE_ENTER_DISTANCE_STUDS = 1.5 -- 목표 지점과 이 이상 떨어지면 Move로 전환
local MOVE_STATE_EXIT_DISTANCE_STUDS = 0.5 -- 이 이하로 가까워지면 Idle로 복귀 (히스테리시스로 경계 떨림 방지)
local STATE_SWITCH_DEBOUNCE_SEC = 0.15 -- 거리 조건이 이 시간 동안 계속 유지돼야 실제로 상태 전환 (경계 근처에서 매 프레임 왔다갔다하며 떨리는 것 방지)
local PET_GROUND_Y_OFFSET = 0 -- 펫 Pivot이 메시 바닥이 아닌 경우의 미세조정치. 실제 비주얼 보고 조정 필요
local HEADING_LERP_ALPHA = 0.15 -- hrp.CFrame의 순간 회전 흔들림을 오프셋 변환 전에 완화하는 별도 스무딩(포지션 SmoothDamp와는 별개)
local FLOOR_Y_LERP_ALPHA = 0.08 -- 발 파츠 기준 지면 높이 추정치를 완만하게 스무딩. 걷기 애니메이션의 발걸음 주기 흔들림을 걸러내되, 실제 스케일 변화(레벨업)에는 여전히 반응함

type PetDefinition = { id: string, modelName: string }

type PetEntry = {
	model: Model,
	animModule: any?,
	joints: { [string]: Motor6D },
	state: string, -- "Idle" | "Move"
	ctx: { [string]: any }, -- 애니메이션 모듈이 프레임 간 값을 저장하는 스크래치 테이블
	groundOffsetY: number, -- Pivot에서 모델 바닥까지의 거리. 이만큼 띄워야 발이 지면에 닿음
	footprintSizeX: number, -- 실측 가로 폭(월드 축 정렬, ModelWorldExtents). 포메이션 열 간격 계산에 사용
	footprintSizeZ: number, -- 실측 세로 깊이(월드 축 정렬, ModelWorldExtents). 포메이션 행 간격/첫 행 거리 계산에 사용
	baseScale: number, -- ServerStorage 템플릿에 저장된 기준 Scale(예: 0.3). 레벨업 시 이 값 * 배율로 재계산
	currentScale: number, -- 현재 실제 Model.Scale(baseScale * 레벨 배율). 애니메이션 핸들러에 넘겨 스터드 단위 오프셋을 스케일에 비례시키는 데 사용
	forwardOrientationOffset: CFrame, -- PET_FORWARD_ORIENTATION_OFFSET_DEGREES 기준 로컬 보정 회전(해당 없으면 identity)
	-- followPosition/followVelocity: bob 등 애니메이션이 섞이지 않은, 팔로우 로직 전용 "클린" 상태.
	-- entry.model:GetPivot()을 그대로 현재값으로 쓰면 애니메이션이 얹은 bob까지 포함된 값이 되어
	-- 되먹임(진동 누적)이 생기므로, 팔로우 계산은 항상 이 필드들만 기준으로 하고 PivotTo도
	-- 이 값들로 조합한 CFrame으로만 세팅한다. velocity는 SmoothDamp(가속도 기반 추종)용 상태.
	followPosition: Vector3,
	followVelocity: Vector3,
	pendingState: string?, -- 전환 대기 중인 state (디바운스: 일정 시간 유지돼야 실제 전환)
	pendingSince: number?, -- pendingState가 처음 감지된 elapsed 시각
}

local petDataCache: any? = nil
local petTemplatesFolder: Instance? = nil
local animStartTime = os.clock() -- 모든 펫이 공유하는 애니메이션 클록 기준점 (동일 타입 펫끼리 위상 동기화)

--- userId → 획득 순서대로 쌓인 PetEntry 목록. 배열 인덱스가 곧 포메이션 슬롯 번호.
local petsByUserId: { [number]: { PetEntry } } = {}

--- userId → 이번 프레임(정확히는 이번 동기 실행 구간)에 지급됐지만 아직 클라이언트로 안 보낸 petId 목록.
--- 트램플/폭발형 펀치처럼 한 번의 공격 판정이 같은 Lua 호출 스택 안에서 여러 건물을 연달아 파괴할 때,
--- 그때마다 PetSavedEvent를 따로따로 쏘지 않고 task.defer로 한 번만 모아서 배열로 보내기 위한 버퍼.
--- task.defer는 현재 동기 실행(예: applyTrampleHitToTargets의 for 루프 전체)이 끝난 뒤 실행되므로,
--- 그 사이 spawnPetForPlayer가 여러 번 호출돼도 이 목록에 전부 쌓인 뒤 한 번에 flush된다.
local pendingPetSavedIdsByUserId: { [number]: { string } } = {}
local petSavedFlushScheduledByUserId: { [number]: boolean } = {}

local function flushPetSavedEvent(player: Player)
	petSavedFlushScheduledByUserId[player.UserId] = nil
	local pending = pendingPetSavedIdsByUserId[player.UserId]
	pendingPetSavedIdsByUserId[player.UserId] = nil
	if not pending or #pending == 0 then
		return
	end
	if not player.Parent then
		return
	end
	local petSavedEvent = ReplicatedStorage:FindFirstChild("PetSavedEvent")
	if petSavedEvent and petSavedEvent:IsA("RemoteEvent") then
		petSavedEvent:FireClient(player, pending)
	end
end

--- spawnPetForPlayer가 펫을 실제로 지급한 직후 호출. 즉시 FireClient하지 않고 pending 목록에 쌓아뒀다가,
--- 이번 동기 실행 구간이 끝나면(task.defer) 그 사이 쌓인 petId를 전부 한 번에 클라이언트로 보낸다.
local function queuePetSavedEvent(player: Player, petId: string)
	local userId = player.UserId
	local pending = pendingPetSavedIdsByUserId[userId]
	if not pending then
		pending = {}
		pendingPetSavedIdsByUserId[userId] = pending
	end
	table.insert(pending, petId)

	if not petSavedFlushScheduledByUserId[userId] then
		petSavedFlushScheduledByUserId[userId] = true
		task.defer(flushPetSavedEvent, player)
	end
end

--- userId → 스무딩된 "heading" 회전(위치는 0,0,0, 회전만 의미 있음). hrp.CFrame의 순간 회전
--- 흔들림이 오프셋 변환에 그대로 곱해지는 것을 막기 위해 회전만 별도로 완만하게 추적한다.
local playerHeadingRotationByUserId: { [number]: CFrame } = {}

--- userId → 스무딩된 지면의 절대 월드 Y. 발 파츠 기준 측정치뿐 아니라 hrp.Position.Y 자체도
--- 걷기 애니메이션 때문에 미세하게 흔들릴 수 있어, "상대값"이 아니라 완전히 독립된 절대 좌표로
--- 스무딩해야 hrp.Position의 흔들림이 섞여 들어오지 않는다.
local playerGroundWorldYByUserId: { [number]: number } = {}

local function loadPetDataRaw(): any?
	if petDataCache then
		return petDataCache
	end
	local ok, result = pcall(function()
		return require(ServerStorage:WaitForChild("DataTable"):WaitForChild(PET_DATA_MODULE_NAME))
	end)
	if ok then
		petDataCache = result
	else
		warn("[PetManager] PetData 로드 실패:", result)
	end
	return petDataCache
end

local function getPetDefinition(petId: string): PetDefinition?
	local raw = loadPetDataRaw()
	local pets = if typeof(raw) == "table" then (raw :: any).pets else nil
	if typeof(pets) ~= "table" then
		return nil
	end
	local def = pets[petId]
	if typeof(def) ~= "table" or typeof(def.modelName) ~= "string" then
		return nil
	end
	return def :: PetDefinition
end

local function getPetTemplatesFolder(): Instance?
	if petTemplatesFolder then
		return petTemplatesFolder
	end
	local folder = ServerStorage:FindFirstChild(PET_TEMPLATES_FOLDER_NAME)
	if not folder then
		warn("[PetManager] ServerStorage." .. PET_TEMPLATES_FOLDER_NAME .. " 없음")
		return nil
	end
	petTemplatesFolder = folder
	return folder
end

local function prepareClonedPetParts(model: Model)
	local legacyScript = model:FindFirstChild(LEGACY_IDLE_SCRIPT_NAME)
	if legacyScript then
		legacyScript:Destroy()
	end

	for _, inst in model:GetDescendants() do
		if inst:IsA("BasePart") then
			inst.Anchored = true
			inst.CanCollide = false
			inst.CanQuery = false
		end
	end
end

local FOOT_JOINT_NAMES = { "FootFLJoint", "FootFRJoint", "FootBLJoint", "FootBRJoint" }

--- 발 파츠(FootFLJoint 등의 Part1) 기준 실제 바닥 월드 Y. GetBoundingBox() 기반 추정과 달리
--- 스케일에 정확히 비례하므로, Model.Scale을 바꿔도(예: 0.2 → 0.3) 오차가 커지지 않는다.
local function computePetFootBottomY(joints: { [string]: Motor6D }): number?
	local bottomY: number? = nil
	for _, jointName in FOOT_JOINT_NAMES do
		local joint = joints[jointName]
		local part = joint and joint.Part1
		if part and part:IsA("BasePart") then
			local footBottom = part.Position.Y - part.Size.Y / 2
			if not bottomY or footBottom < bottomY then
				bottomY = footBottom
			end
		end
	end
	return bottomY
end

--- Pivot(PrimaryPart)에서 모델 바닥까지의 거리. Pivot이 메시 중심 부근에 있는 모델이라도
--- 이만큼 띄워주면 발이 지면에 닿는다. Clone 직후(월드 위치가 아직 템플릿 그대로일 때) 호출해야 함.
--- 발 조인트(FOOT_JOINT_NAMES)를 우선 사용하고, 없는 펫 종류는 GetBoundingBox()로 fallback한다.
local function computePetGroundOffsetY(pet: Model, joints: { [string]: Motor6D }): number
	local pivotY = pet:GetPivot().Position.Y

	local footBottomY = computePetFootBottomY(joints)
	if footBottomY then
		return pivotY - footBottomY
	end

	local ok, boundsCFrame, boundsSize = pcall(function()
		return pet:GetBoundingBox()
	end)
	if not ok then
		return 0
	end
	local bottomY = boundsCFrame.Position.Y - boundsSize.Y / 2
	return pivotY - bottomY
end

local function roundToHundredths(value: number): number
	return math.floor(value * 100 + 0.5) / 100
end

--- 플레이어 레벨에 대응하는 펫 Scale = round(CharacterScaleCurve.scaleByLevel[level] / 6, 2).
--- pet baseScale과 무관하게 이 값을 그대로 최종 Model.Scale로 쓴다. 레벨은 CharacterScaleCurve.meta의
--- startingLevel~maxLevel 범위로 클램프.
local function getPetScaleForLevel(level: number): number
	local arr = CharacterScaleCurve.scaleByLevel
	if typeof(arr) ~= "table" or #arr == 0 then
		return 1
	end

	local meta = CharacterScaleCurve.meta
	local minLevel = if typeof(meta) == "table" and typeof(meta.startingLevel) == "number" then meta.startingLevel else 1
	local maxLevel = if typeof(meta) == "table" and typeof(meta.maxLevel) == "number" then meta.maxLevel else #arr

	local clampedLevel = math.clamp(math.floor(level), minLevel, maxLevel)
	local value = arr[clampedLevel]
	if typeof(value) ~= "number" or value <= 0 then
		return 1
	end

	return roundToHundredths(value / 6)
end

--- Unity의 SmoothDamp를 Vector3용으로 옮긴 것. 목표가 갑자기 바뀌어도 속도(velocity)가
--- 누적된 관성에 따라 매끄럽게 방향을 트는 "가속도 기반" 추종을 만든다(단순 Lerp는 속도 개념이
--- 없어 목표가 바뀌면 그 즉시 방향이 꺾인다). smoothTime은 대략 목표에 도달하는 데 걸리는 시간.
local function smoothDampVector3(
	current: Vector3,
	target: Vector3,
	velocity: Vector3,
	smoothTime: number,
	dt: number,
	maxSpeed: number
): (Vector3, Vector3)
	smoothTime = math.max(0.0001, smoothTime)
	local omega = 2 / smoothTime
	local x = omega * dt
	local exp = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)

	local change = current - target
	local maxChange = maxSpeed * smoothTime
	if maxChange > 0 and change.Magnitude > maxChange then
		change = change.Unit * maxChange
	end
	local clampedTarget = current - change

	local temp = (velocity + change * omega) * dt
	local newVelocity = (velocity - temp * omega) * exp
	local newPosition = clampedTarget + (change + temp) * exp

	if dt > 1e-5 then
		local origDiff = target - current
		local outDiff = newPosition - target
		if origDiff:Dot(outDiff) > 0 then
			newPosition = target
			newVelocity = (newPosition - target) / dt
		end
	end

	return newPosition, newVelocity
end

type FormationSpacing = {
	cellStuds: number,
	rowGapStuds: number,
	frontGapStuds: number,
	oddColBackStuds: number,
}

--- list 안의 모든 펫들 중 최대 실측 가로/세로(비어있으면 0, 0)
local function getMaxPetFootprint(list: { PetEntry }): (number, number)
	local maxSizeX = 0
	local maxSizeZ = 0
	for _, entry in list do
		if entry.footprintSizeX > maxSizeX then
			maxSizeX = entry.footprintSizeX
		end
		if entry.footprintSizeZ > maxSizeZ then
			maxSizeZ = entry.footprintSizeZ
		end
	end
	return maxSizeX, maxSizeZ
end

--- 대형 간격을 "가장 큰 펫" 기준으로 계산한다. CELL_STUDS 등 모듈 상수는 최소값(하한선)으로만
--- 쓰이고, 펫이 그보다 크면(Model.Scale 확대 등) 실측 크기 + 여백만큼 자동으로 넓어진다.
local function computeFormationSpacing(
	maxFootprintSizeX: number,
	maxFootprintSizeZ: number,
	characterScale: number
): FormationSpacing
	return {
		cellStuds = math.max(CELL_STUDS, maxFootprintSizeX + CELL_PADDING_STUDS),
		rowGapStuds = math.max(ROW_GAP_STUDS, maxFootprintSizeZ + maxFootprintSizeX * ROW_GAP_PADDING_RATIO),
		frontGapStuds = math.max(
			FRONT_GAP_STUDS * characterScale,
			maxFootprintSizeZ / 2 + FRONT_GAP_PADDING_STUDS * characterScale
		),
		oddColBackStuds = math.max(ODD_COL_BACK_STUDS, maxFootprintSizeX * ODD_COL_BACK_RATIO),
	}
end

--- 슬롯 index(1부터, 획득 순서)에 대응하는 플레이어 로컬 좌표계 기준 오프셋
local function getSlotLocalOffset(index: number, groundLocalY: number, spacing: FormationSpacing): CFrame
	local zeroBased = index - 1
	local rowIndex = math.floor(zeroBased / ROW_WIDTH)
	local posInRow = (zeroBased % ROW_WIDTH) + 1
	local col = ROW_FILL_ORDER[posInRow] or posInRow
	local centerCol = (ROW_WIDTH + 1) / 2
	local localX = (col - centerCol) * spacing.cellStuds
	local localZ = spacing.frontGapStuds + rowIndex * spacing.rowGapStuds
	if col % 2 == 1 then
		localZ += spacing.oddColBackStuds
	end
	return CFrame.new(localX, groundLocalY, localZ)
end

--- 캐릭터 발바닥의 실제 월드 Y좌표. HipHeight는 Model:ScaleTo() 기반 스케일 변경 시
--- 값이 갱신되지 않을 수 있어(레벨업 시 펫이 뜨는 원인), 현재 스케일이 그대로 반영되는
--- 발 파츠 Position/Size를 직접 측정한다.
local function getCharacterFootBottomY(character: Model): number?
	local leftFoot = character:FindFirstChild("LeftFoot") or character:FindFirstChild("Left Leg")
	local rightFoot = character:FindFirstChild("RightFoot") or character:FindFirstChild("Right Leg")
	if not (leftFoot and leftFoot:IsA("BasePart") and rightFoot and rightFoot:IsA("BasePart")) then
		return nil
	end
	local leftBottom = leftFoot.Position.Y - leftFoot.Size.Y / 2
	local rightBottom = rightFoot.Position.Y - rightFoot.Size.Y / 2
	return math.min(leftBottom, rightBottom)
end

--- 스폰 시점에 펫이 서 있어야 할 포메이션 슬롯의 CFrame을 즉시 계산한다.
--- 스폰 직후 이 위치로 바로 PivotTo해서, 클론 시점의 템플릿 위치(먼 곳)에서부터
--- SmoothDamp로 서서히 다가오느라 한동안 안 보이는 문제를 없앤다.
local function computeSpawnCFrame(
	character: Model,
	index: number,
	groundOffsetY: number,
	spacing: FormationSpacing,
	forwardOrientationOffset: CFrame
): CFrame?
	local hrpInst = character:FindFirstChild("HumanoidRootPart")
	if not (hrpInst and hrpInst:IsA("BasePart")) then
		return nil
	end
	local hrp = hrpInst :: BasePart

	local floorLocalY: number
	local footBottomY = getCharacterFootBottomY(character)
	if footBottomY then
		floorLocalY = footBottomY - hrp.Position.Y
	else
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		floorLocalY = if humanoid then -humanoid.HipHeight else 0
	end
	floorLocalY += PET_GROUND_Y_OFFSET

	local groundLocalY = floorLocalY + groundOffsetY

	return hrp.CFrame * getSlotLocalOffset(index, groundLocalY, spacing) * forwardOrientationOffset
end

function PetManager.spawnPetForPlayer(player: Player, petId: string?)
	local character = player.Character
	if not character then
		return
	end

	local existingList = petsByUserId[player.UserId]
	if existingList and #existingList >= MAX_PETS_PER_PLAYER then
		return
	end

	local def = getPetDefinition(petId or DEFAULT_PET_ID)
	if not def then
		warn("[PetManager] PetData에 없는 펫 id:", petId or DEFAULT_PET_ID)
		return
	end

	local templatesFolder = getPetTemplatesFolder()
	if not templatesFolder then
		return
	end

	local template = templatesFolder:FindFirstChild(def.modelName)
	if not (template and template:IsA("Model")) then
		warn("[PetManager] ServerStorage." .. PET_TEMPLATES_FOLDER_NAME .. "." .. def.modelName .. " (Model) 없음")
		return
	end

	local baseScaleOk, baseScale = pcall(function()
		return (template :: Model):GetScale()
	end)
	if not baseScaleOk or typeof(baseScale) ~= "number" or baseScale <= 0 then
		baseScale = 1
	end

	local pet = (template :: Model):Clone()
	prepareClonedPetParts(pet)
	pet.Name = "Pet_" .. def.id
	pet.Parent = character

	local targetScale = getPetScaleForLevel(XpHandler.getLevel(player.UserId))
	local currentScaleOk, currentScale = pcall(function()
		return pet:GetScale()
	end)
	if not currentScaleOk then
		currentScale = baseScale
	end
	if math.abs(targetScale - currentScale) > 1e-4 then
		local scaleOk, scaleErr = pcall(function()
			pet:ScaleTo(targetScale)
		end)
		if not scaleOk then
			warn("[PetManager] 펫 스케일 적용 실패:", scaleErr)
		end
	end

	local animModule = PetAnimationRegistry[def.id]
	if not animModule then
		warn("[PetManager] PetAnimationRegistry에 없는 펫 id (애니메이션 없이 스폰됨):", def.id)
	end

	local list = petsByUserId[player.UserId]
	if not list then
		list = {}
		petsByUserId[player.UserId] = list
	end
	local slotIndex = #list + 1

	local joints = MotorJointAnimator.collectMotor6Ds(pet)
	local groundOffsetY = computePetGroundOffsetY(pet, joints)
	local footprintExtents = ModelWorldExtents.compute(pet)
	local forwardOffsetDegrees = PET_FORWARD_ORIENTATION_OFFSET_DEGREES[def.id] or 0
	local forwardOrientationOffset = CFrame.Angles(0, math.rad(forwardOffsetDegrees), 0)

	-- 대형 간격은 "가장 큰 펫" 기준이어야 하므로, 아직 list에 들어가지 않은 이 신규 펫의 실측
	-- 크기도 기존 펫들과 함께 비교해 최댓값을 구한다.
	local maxSizeX, maxSizeZ = getMaxPetFootprint(list)
	maxSizeX = math.max(maxSizeX, footprintExtents.sizeX)
	maxSizeZ = math.max(maxSizeZ, footprintExtents.sizeZ)
	local scale = ScaleModule.getCharacterScale(character)
	local spacing = computeFormationSpacing(maxSizeX, maxSizeZ, scale)

	local spawnCFrame = computeSpawnCFrame(character, slotIndex, groundOffsetY, spacing, forwardOrientationOffset)
	if spawnCFrame then
		pet:PivotTo(spawnCFrame)
	end

	local entry: PetEntry = {
		model = pet,
		animModule = animModule,
		joints = joints,
		state = "Idle",
		ctx = {},
		groundOffsetY = groundOffsetY,
		footprintSizeX = footprintExtents.sizeX,
		footprintSizeZ = footprintExtents.sizeZ,
		baseScale = baseScale,
		currentScale = targetScale,
		forwardOrientationOffset = forwardOrientationOffset,
		followPosition = (spawnCFrame or pet:GetPivot()).Position,
		followVelocity = Vector3.zero,
		pendingState = nil,
		pendingSince = nil,
	}

	table.insert(list, entry)

	queuePetSavedEvent(player, def.id)
	MissionHelper.incrementProgress(player, 6)
end

--- CombatHandler.destroyDamageableModel()에서 model:Destroy() 전에 호출.
function PetManager.onBuildingDestroyed(player: Player, model: Model)
	if not model:FindFirstChild("SpeechBubbleGui") then
		return
	end
	-- 방어 코드: SpeechBubbleManager는 티어 1~8 건물만 대상으로 삼고 스테이지 보스는 애초에
	-- 다른 위치(StageMap 직계 자식)에 있어 대상이 되지 않지만, 맵 구성이 바뀌거나 테스트 중
	-- SpeechBubbleGui가 잘못 붙는 경우에 대비해 보스는 명시적으로 제외한다.
	local bossAttributeName = GameSettings.Combat.StageBossAttributeName or "StageBoss"
	if model:GetAttribute(bossAttributeName) == true then
		return
	end

	-- 하드코딩된 목록 대신 PetData에 등록된 모든 펫 id 중 랜덤으로 지급 — 펫이 추가/제거돼도
	-- 이 함수를 따로 손볼 필요가 없다.
	local raw = loadPetDataRaw()
	local pets = if typeof(raw) == "table" then (raw :: any).pets else nil
	if typeof(pets) ~= "table" then
		return
	end
	local dropIds = {}
	for petId in pets do
		table.insert(dropIds, petId)
	end
	if #dropIds == 0 then
		return
	end

	PetManager.spawnPetForPlayer(player, dropIds[math.random(1, #dropIds)])
end

--- init.server.luau의 XpHandler.setApplyScaleCallback에서 플레이어 레벨이 바뀔 때마다 호출.
--- 새 레벨의 getPetScaleForLevel() 값을 모든 펫에 동일하게 ScaleTo한다. 매 레벨업마다 호출해도
--- 안전(스케일 변화가 없으면 조기 반환).
function PetManager.onPlayerLevelUp(player: Player, newLevel: number)
	local list = petsByUserId[player.UserId]
	if not list or #list == 0 then
		return
	end

	local targetScale = getPetScaleForLevel(newLevel)

	for _, entry in list do
		if not entry.model.Parent then
			continue
		end

		local currentScaleOk, currentScale = pcall(function()
			return entry.model:GetScale()
		end)
		if currentScaleOk and math.abs(targetScale - currentScale) < 1e-4 then
			continue
		end

		local scaleOk, scaleErr = pcall(function()
			entry.model:ScaleTo(targetScale)
		end)
		if not scaleOk then
			warn("[PetManager] 레벨업 펫 스케일 적용 실패:", scaleErr)
			continue
		end

		entry.groundOffsetY = computePetGroundOffsetY(entry.model, entry.joints)
		local extents = ModelWorldExtents.compute(entry.model)
		entry.footprintSizeX = extents.sizeX
		entry.footprintSizeZ = extents.sizeZ
		entry.currentScale = targetScale
	end
end

local function reparentPetsToCharacter(player: Player, character: Model)
	local list = petsByUserId[player.UserId]
	if not list then
		return
	end
	for _, entry in list do
		if entry.model.Parent then
			entry.model.Parent = character
		end
	end
end

local function clearPlayerPets(player: Player)
	local list = petsByUserId[player.UserId]
	if not list then
		return
	end
	for _, entry in list do
		if entry.model.Parent then
			entry.model:Destroy()
		end
	end
	petsByUserId[player.UserId] = nil
	playerHeadingRotationByUserId[player.UserId] = nil
	playerGroundWorldYByUserId[player.UserId] = nil
end

local function updateAllPets(dt: number)
	local elapsed = os.clock() - animStartTime

	for userId, list in petsByUserId do
		local player = Players:GetPlayerByUserId(userId)
		local character = player and player.Character
		local hrpInst = character and character:FindFirstChild("HumanoidRootPart")
		if not (hrpInst and hrpInst:IsA("BasePart")) then
			continue
		end
		local hrp = hrpInst :: BasePart

		-- 발 파츠 기준 측정치(혹은 HipHeight 대체값)를 "hrp 기준 상대값"으로 스무딩하면,
		-- hrp.Position.Y 자체가 걷기 애니메이션 때문에 미세하게 흔들릴 때 그 흔들림이 스무딩을
		-- 우회해서 그대로 섞여 들어온다. 그래서 상대값이 아니라 완전히 독립된 절대 월드 Y로
		-- 스무딩하고, 최종 목표 위치의 Y는 이 값으로 통째로 대체한다(hrp.Position.Y를 아예 안 씀).
		local rawGroundWorldY: number
		local footBottomY = getCharacterFootBottomY(character :: Model)
		if footBottomY then
			rawGroundWorldY = footBottomY
		else
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			rawGroundWorldY = if humanoid then hrp.Position.Y - humanoid.HipHeight else hrp.Position.Y
		end

		local prevGroundWorldY = playerGroundWorldYByUserId[userId] or rawGroundWorldY
		local smoothedGroundWorldY = prevGroundWorldY + (rawGroundWorldY - prevGroundWorldY) * FLOOR_Y_LERP_ALPHA
		playerGroundWorldYByUserId[userId] = smoothedGroundWorldY

		local scale = ScaleModule.getCharacterScale(character :: Model)
		local maxSizeX, maxSizeZ = getMaxPetFootprint(list)
		local spacing = computeFormationSpacing(maxSizeX, maxSizeZ, scale)

		-- 레벨업으로 플레이어 WalkSpeed가 오르면(ScaleModule.calculateWalkSpeed) 포메이션 추종
		-- 속도 상한도 같이 올려서, 고레벨에서 펫이 플레이어를 못 따라가 계속 처지는(거북이처럼
		-- 느려 보이는) 현상을 막는다.
		local characterHumanoid = (character :: Model):FindFirstChildOfClass("Humanoid")
		local playerWalkSpeed = if characterHumanoid then characterHumanoid.WalkSpeed else 16
		local formationFollowMaxSpeed = math.max(FOLLOW_MAX_SPEED_STUDS, playerWalkSpeed * FOLLOW_MAX_SPEED_PLAYER_MULTIPLIER)

		-- hrp.CFrame의 회전만 따로 완만하게 스무딩 (위치는 매 프레임 최신값 그대로 사용).
		-- 오프셋을 raw 회전으로 변환하면 캐릭터가 이동 중 방향을 미세 조정할 때마다 그 흔들림이
		-- 슬롯 위치에 그대로 곱해져 뒷줄일수록 크게 흔들리므로, 여기서 먼저 걸러낸다.
		local rawHeadingRotation = hrp.CFrame - hrp.CFrame.Position
		local prevHeadingRotation = playerHeadingRotationByUserId[userId] or rawHeadingRotation
		local headingRotation = prevHeadingRotation:Lerp(rawHeadingRotation, HEADING_LERP_ALPHA)
		playerHeadingRotationByUserId[userId] = headingRotation
		local heading = headingRotation + hrp.Position

		for index, entry in list do
			if not entry.model.Parent then
				continue
			end

			-- Y는 targetCFrame의 변환 결과를 쓰지 않고 smoothedGroundWorldY로 통째로 대체하므로
			-- 여기서는 X/Z만 의미 있게 만들면 되고, 두 번째 인자(로컬 Y)는 0으로 둬도 무방하다.
			local formationCFrame = heading * getSlotLocalOffset(index, 0, spacing)
			local restTargetPosition = Vector3.new(
				formationCFrame.Position.X,
				smoothedGroundWorldY + PET_GROUND_Y_OFFSET + entry.groundOffsetY,
				formationCFrame.Position.Z
			)
			local targetRotation = formationCFrame - formationCFrame.Position

			-- Idle ↔ Move: 거리 기반 히스테리시스(경계 근처에서 매 프레임 왔다갔다하며 떨리는 것 방지)
			local distance = (restTargetPosition - entry.followPosition).Magnitude
			local desiredState = entry.state
			if entry.state ~= "Move" and distance > MOVE_STATE_ENTER_DISTANCE_STUDS then
				desiredState = "Move"
			elseif entry.state == "Move" and distance < MOVE_STATE_EXIT_DISTANCE_STUDS then
				desiredState = "Idle"
			end

			if desiredState == entry.state then
				entry.pendingState = nil
				entry.pendingSince = nil
			elseif entry.pendingState ~= desiredState then
				entry.pendingState = desiredState
				entry.pendingSince = elapsed
			elseif elapsed - (entry.pendingSince :: number) >= STATE_SWITCH_DEBOUNCE_SEC then
				entry.state = desiredState
				entry.pendingState = nil
				entry.pendingSince = nil
			end

			-- 단순 Lerp 대신 가속도 기반 SmoothDamp: 목표 방향이 바뀌어도 관성 때문에
			-- 가던 방향으로 살짝 더 갔다가 자연스럽게 방향을 트는 "엑셀레이터" 느낌으로 이동.
			local newPosition, newVelocity = smoothDampVector3(
				entry.followPosition,
				restTargetPosition,
				entry.followVelocity,
				FOLLOW_SMOOTH_TIME_SEC,
				dt,
				formationFollowMaxSpeed
			)
			entry.followPosition = newPosition
			entry.followVelocity = newVelocity

			local finalCFrame = CFrame.new(newPosition) * targetRotation * entry.forwardOrientationOffset
			entry.model:PivotTo(finalCFrame)

			local handler = entry.animModule and entry.animModule[entry.state]
			if handler then
				handler(entry.model, entry.joints, elapsed, entry.ctx, entry.currentScale)
			end
		end
	end
end

function PetManager.init()
	if initialized then
		return
	end
	initialized = true

	local function hookPlayer(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			reparentPetsToCharacter(player, character)
		end)
	end

	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
	Players.PlayerAdded:Connect(hookPlayer)

	Players.PlayerRemoving:Connect(clearPlayerPets)

	RunService.Heartbeat:Connect(updateAllPets)

	print("[PetManager] 초기화 완료")
end

return PetManager
