--[[
	"펫 건물 마킹 시스템.md" 기반 펫 건물 마킹.

	StageManager.StageStartedAt 기준 전역 고정 사이클로 동작한다(플레이어별 랜덤 루프였던 구버전과
	달리 모든 플레이어에게 동일한 절대 시각 t=35,40,85,90...에 이벤트가 발생):
	- t = MarkStartTime-AreaNoticeTime(35초): 플레이어별 위치/레벨 기준 Area 3개(AreaCount) 선정 +
	  각 Area에 대한 "프리뷰" 건물 탐색으로 대상 건물의 실측 높이를 얻어 ServerStorage.UFO/
	  PetMarkerArea를 Area 중심에 스폰(사전 안내 이펙트). UFO Scale은 그 Area의 AreaRadius(지름
	  16 studs = Scale 1)로 결정되고, 이 프리뷰 탐색은 건물을 실제로 마킹하지 않는 순수 조회다.
	- t = MarkStartTime(40초): 프리뷰 UFO를 전부 제거하고, 같은 Area들에 대해 "실제" 건물 탐색을
	  다시 수행(이 시점 최신 레벨 사용)해 성공한 Area마다 SpeechBubbleGui를 부착한다. 이 마커들이
	  하나의 그룹을 이뤄, 그중 하나가 파괴되면(SpeechBubbleManager.onBuildingClaimed) 그룹 전체가
	  종료되고, 아무것도 파괴되지 않은 채 RescueDuration(10초)이 지나면 그룹 전체가 자동 정리된다.
	- Lv.9(LevelXpCurve.meta.maxLevel) 도달 플레이어는 그 시점 이후 새 Area/UFO/그룹 생성에서
	  제외된다(이미 진행 중인 그룹은 그대로 유지).

	init(stageMap)/startForPlayer(player) 시그니처는 구버전과 동일하게 유지한다(init.server.luau가
	그대로 호출). startForPlayer는 최초 1회 호출될 때만 전역 사이클을 시작하는 idempotent 진입점이다.

	후보 스캔~SpeechBubbleGui 부착 사이에는 yield가 없어야 한다(동시성 가드 없이도 다른
	플레이어/Area의 마킹 시도와 겹쳐 같은 건물이 중복 마킹되는 것을 막기 위함). 이 불변식을 지키기
	위해 한 틱의 모든 플레이어/Area 처리는 단일 스레드에서 순차적으로 이뤄진다.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ModelWorldExtents = require(Shared.Utils.ModelWorldExtents)
local ModelGroundSnap = require(Shared.Utils.ModelGroundSnap)
local ArenaBounds = require(Shared.Utils.ArenaBounds)
local PetMarkerAreaVisualSync = require(Shared.Utils.PetMarkerAreaVisualSync)
local PetMarkConfig = require(Shared.Config.PetMarkConfig)
local LevelXpCurve = require(Shared.Config.LevelXpCurve)
local GameManager = require(Shared.Managers.GameManager)
local PetMarkAreaSelector = require(script.Parent.PetMarkAreaSelector)
local StageManager = require(script.Parent.StageManager)
local XpHandler = require(script.Parent.XpHandler)

local SpeechBubbleManager = {}

local TOP_GAP = 1.5 -- 모델 상단과 말풍선 사이 간격 (studs)
local TEMPLATE_NAME = "SpeechBubbleTemplate"
local UFO_TEMPLATE_NAME = "UFO"
local PET_MARKER_AREA_TEMPLATE_NAME = "PetMarkerArea"

local MAX_PLAYER_LEVEL = (LevelXpCurve.meta and LevelXpCurve.meta.maxLevel) or 9

-- UFO끼리 실제로 겹쳐 보이지 않도록 둘 사이에 추가로 확보하는 여유 간격(스터드).
local UFO_OVERLAP_PADDING_STUDS = 2

-- UFO Scale 기준: 이 지름(스터드)이 Scale=1에 대응한다. 즉 AreaRadius(반지름)의 UFO Scale은
-- (AreaRadius * 2) / UFO_SCALE_REFERENCE_DIAMETER_STUDS. 예) AreaRadius=15 → 지름 30 → Scale 1.875.
local UFO_SCALE_REFERENCE_DIAMETER_STUDS = 16

-- UFO 등장 연출: 최종 위치보다 이만큼 위에서 나타나 하강한다. Model 전체 이동은 TweenService의
-- WorldPivot 트윈이 이 프로젝트 환경에서 재생되지 않는 게 실측 확인돼(Model에 프로퍼티 트윈이
-- 먹지 않음), RunService.Heartbeat로 직접 pivot을 매 프레임 보간한다(아래 tweenModelPivot).
local UFO_DROP_IN_OFFSET_STUDS = 10
local UFO_DROP_IN_DURATION = 0.5
-- UFO Beam 등장 연출: 하강이 끝난 뒤 Transparency 1(안 보임) -> UFO_BEAM_VISIBLE_TRANSPARENCY로 Fade.
-- Beam은 일반 BasePart라 TweenService Transparency 트윈이 정상 동작한다.
local UFO_BEAM_FADE_TWEEN_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local UFO_BEAM_VISIBLE_TRANSPARENCY = 0.8

-- StageMap 직계 자식 중 이름이 "Model"인 것 전부(구역/Zone마다 하나씩 있을 수 있음 — 풀맵처럼 여러
-- Zone을 이어붙인 맵은 "Model"이라는 동일 이름 컨테이너가 여러 개 존재한다. FindFirstChild로 하나만
-- 집으면 그 Zone의 건물만 보여서, 플레이어가 다른 Zone에 있을 때 근처에 후보가 전혀 안 보이는
-- 원인이었다).
local modelFolders: { Instance } = {}
local template: Instance? = nil
local ufoTemplate: Instance? = nil
local petMarkerAreaTemplate: Instance? = nil
--- ufoTemplate의 기준(Scale=1) 상태 수평 반경. init()에서 1회 계산해 캐싱(실제 UFO 비주얼 반경
--- = 이 값 * ufoScaleForAreaRadius(area.radius)).
local ufoBaseRadius: number? = nil

local cycleStarted = false
--- init()이 끝나기 전에 startForPlayer가 먼저 호출된 경우 true로 세팅된다. init() 마지막에
--- modelFolders/template이 정상 준비됐으면 이 플래그를 보고 그때 사이클을 대신 시작해준다
--- (레이스로 인한 최초 시작 요청 유실 방지 — 그 요청을 보낸 플레이어가 누구였는지는 중요하지
--- 않다. 어차피 사이클은 전역 1회만 시작하면 되는 idempotent 동작이라서).
local pendingCycleStart = false
--- 현재 실행 중인 전역 사이클(runGlobalCycle) 스레드. 디버그 스폰(X키)이 메인 쿨타임을 재정렬할 때
--- 이 스레드를 취소하고 새로 시작하기 위해 보관한다.
local globalCycleThread: thread? = nil

type Area = { center: Vector3, radius: number }

type Group = {
	markers: { Model },
	expireThread: thread?,
}

--- userId -> 35초 시점에 선정된 Area 목록(40초에 실제 마킹할 때 사용, 그 사이 소비되면 nil로 비움)
local cachedAreasByUserId: { [number]: { Area } } = {}
--- userId -> 35~40초 사이에만 존재하는 프리뷰 UFO 목록
local pendingUfosByUserId: { [number]: { Model } } = {}
--- userId -> 35~40초 사이에만 존재하는 프리뷰 PetMarkerArea(지면 마커) 목록
local pendingPetMarkerAreasByUserId: { [number]: { Model } } = {}
--- userId -> 현재 진행 중인 펫마커 그룹(마커 3개 이하)
local groupsByUserId: { [number]: Group } = {}
--- 마킹된 건물 Model -> 그 마커를 소유한 그룹의 userId (파괴한 플레이어와 다를 수 있음)
local markerOwnerByModel: { [Model]: number } = {}

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

--- Area 사전 안내(35초)를 클라이언트에 알리는 훅. 구체적인 이펙트/UI는 기획서 10장에서 추후
--- 논의 대상으로 명시했으므로, payload만 전달하고 클라이언트 처리 로직은 작성하지 않는다.
local areaNoticeEvent = ensureRemoteEvent("PetMarkAreaNoticeEvent")

--- GameScreenGui.PetTimer(우주선/펫 구출 카운트다운 HUD)에 현재 페이즈와 그 시점 기준 남은
--- 시간(초)을 전파한다. 매초 다시 보내는 대신 페이즈 전환 시점(전역 사이클 시작/실제 마킹 시점)에
--- 한 번만 쏘고, 클라이언트가 자체 시계로 로컬 카운트다운한다(GameTimer/Fever와 동일한 컨벤션).
local petTimerPhaseEvent = ensureRemoteEvent("PetTimerPhaseEvent")

local function setupBubble(model: Model)
	-- 공격판정용 투명 파츠(예: 세로로 큰 히트박스)를 제외한 실제 렌더링 영역 기준으로 크기/높이 계산.
	-- 보이는 파츠가 없으면(전부 투명 등) 기존 방식으로 폴백.
	local extents = ModelWorldExtents.computeVisible(model) or ModelWorldExtents.compute(model)
	if extents.sizeX == 0 and extents.sizeY == 0 and extents.sizeZ == 0 then
		return
	end

	local bubble = (template :: Instance):Clone()
	bubble.Name = "SpeechBubbleGui"

	-- Size: 실제 월드 수평 크기의 85% (최소 4 studs, 상한 없음)
	local maxHorizontal = math.max(extents.sizeX, extents.sizeZ)
	local bubbleWidth = math.max(maxHorizontal * 0.85, 4)
	local bubbleHeight = bubbleWidth * 0.5
	;(bubble :: any).Size = UDim2.new(bubbleWidth, 0, bubbleHeight, 0)

	-- 목표 world Y: 건물 꼭대기 위에 배치 (건물마다 실제 높이가 다르므로 절대값 캡 없이 그대로 사용)
	local bubbleWorldY = extents.topY + (bubbleHeight / 2) + TOP_GAP

	-- Adornee를 model(Model 전체)로 걸면 Roblox 엔진이 BillboardGui 위치를 잡을 때 그 Model의
	-- 전체 파츠(공격판정용 투명 콜라이더 포함)를 반영한 내부 기준을 사용해서, computeVisible로
	-- 정확히 계산해도 화면 위치는 여전히 그 콜라이더 영향을 받는다(실측 확인됨).
	-- computeVisible의 집계 중심(centerX/centerZ)에 anchor를 두면, 파츠가 흩어진 모델에서는
	-- 그 중심점이 실제 지오메트리가 없는 빈 공간을 가리켜 바닥에 깔리는 문제가 있었다(실측 확인됨).
	-- topPart를 직접 Adornee로 삼고 StudsOffset(WorldSpace)로 띄우면, 방향성 있는 Prop(가구 등,
	-- 보통 Y축만 회전)에서 X/Z가 옆으로 밀렸다(실측 확인됨).
	-- 그래서 회전이 전혀 없는(Orientation=0) 소형 anchor Part를 목표 절대 위치(X/Z는 실제 존재하는
	-- topPart 좌표, Y는 bubbleWorldY)에 직접 두고, 오프셋 없이(0,0,0) Adornee로 쓴다.
	local topPart = ModelWorldExtents.findTopVisiblePart(model)
	local anchorX = extents.centerX
	local anchorZ = extents.centerZ
	if topPart then
		anchorX = topPart.Position.X
		anchorZ = topPart.Position.Z
	end

	local anchor = Instance.new("Part")
	anchor.Name = "SpeechBubbleAnchor"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Anchored = true
	anchor.CFrame = CFrame.new(anchorX, bubbleWorldY, anchorZ)
	anchor.Parent = model

	;(bubble :: any).Adornee = anchor
	;(bubble :: any).StudsOffset = Vector3.new(0, 0, 0)
	;(bubble :: any).StudsOffsetWorldSpace = Vector3.new(0, 0, 0)
	;(bubble :: any).ExtentsOffset = Vector3.new(0, 0, 0)

	bubble.Parent = model
end

local function removeMarkerFromModel(model: Model)
	local bubble = model:FindFirstChild("SpeechBubbleGui")
	if bubble then
		bubble:Destroy()
	end
	local anchor = model:FindFirstChild("SpeechBubbleAnchor")
	if anchor then
		anchor:Destroy()
	end
end

local function levelOf(player: Player): number
	return XpHandler.getLevel(player.UserId)
end

local function clearPendingUfos(userId: number)
	local ufos = pendingUfosByUserId[userId]
	if not ufos then
		return
	end
	for _, ufo in ufos do
		if ufo.Parent then
			ufo:Destroy()
		end
	end
	pendingUfosByUserId[userId] = nil
end

local function clearPendingPetMarkerAreas(userId: number)
	local areas = pendingPetMarkerAreasByUserId[userId]
	if not areas then
		return
	end
	for _, area in areas do
		if area.Parent then
			area:Destroy()
		end
	end
	pendingPetMarkerAreasByUserId[userId] = nil
end

local function clearGroup(userId: number)
	local group = groupsByUserId[userId]
	if not group then
		return
	end
	-- 타임아웃(scheduleGroupExpiry)이 자연 발화해 그 콜백 내부에서 clearGroup을 호출하는 경우,
	-- group.expireThread는 지금 이 코드를 실행 중인 스레드 자신이다 — 실행 중인 스레드를
	-- task.cancel로 취소하려 하면 "cannot cancel thread" 에러가 나므로 그 경우는 건너뛴다.
	if group.expireThread and group.expireThread ~= coroutine.running() then
		task.cancel(group.expireThread)
	end
	-- expireThread를 취소했으므로, 자연 만료 시 그 콜백이 해줬을 SpeechBubbleGui/Anchor 제거를
	-- 여기서 대신 해줘야 한다. 이게 없으면(과거 버전) 이 건물들이 SpeechBubbleGui를 영구히 단
	-- 채로 남아 collectCandidates에서 계속 "이미 마킹됨"으로 제외된다 — 방어적 재정리(다음 마킹
	-- 사이클 시작 전, 디버그 재시도 등)로 clearGroup이 자연 만료보다 먼저 불릴 때마다 근처 건물이
	-- 하나씩 영구히 사라져, 결국 탐색이 점점 더 먼 곳까지 확장되는 원인이었다.
	for _, model in group.markers do
		markerOwnerByModel[model] = nil
		if model.Parent then
			removeMarkerFromModel(model)
		end
	end
	groupsByUserId[userId] = nil
end

--- CombatHandler.destroyDamageableModel()에서 model:Destroy() 전에 호출.
--- model이 어느 그룹의 마커였다면(파괴한 플레이어와 무관하게) 그 그룹의 나머지 마커를 즉시
--- 제거하고 그룹을 종료한다.
function SpeechBubbleManager.onBuildingClaimed(_: Player, model: Model)
	local userId = markerOwnerByModel[model]
	if not userId then
		return
	end
	-- clearGroup이 group.markers 전체(파괴 대상 model 포함)의 SpeechBubbleGui/Anchor를 정리해준다.
	clearGroup(userId)
end

local function scheduleGroupExpiry(userId: number)
	return task.delay(PetMarkConfig.RescueDuration, function()
		local group = groupsByUserId[userId]
		if not group then
			return
		end
		clearGroup(userId)
	end)
end

-- 지면 raycast가 장식물(램프/가드레일 등 얇고 높은 소품)을 잘못 맞혀 그 위에 "착지"하면
-- 실제 지면보다 떠 보인다 — 이 얇은 지형/장식물 문제는 raycast가 성공(hit)한 채로 발생하므로
-- 실패 감지(nil)로는 못 잡는다. 대신 플레이어 자신은 육안으로 정상적으로 지면에 서 있다는
-- 사실을 신뢰 기준으로 삼아, Area의 raycast 결과가 그 기준과 너무 차이 나면 그 표면만 제외하고
-- 재시도한다.
local GROUND_Y_TOLERANCE_STUDS = 15
local MAX_GROUND_RETRIES = 5

--- 건물 지붕이나(모델 폴더) 플레이어 캐릭터 자신(레벨업으로 몸이 커지면 Area 중심 근처를
--- 실제로 뒤덮을 수 있음 — CharacterScaleCurve 기준 최대 43배)에 "착지"해 실제 지면보다 떠
--- 보이는 것을 막기 위해 건물 폴더 + 접속 중인 모든 플레이어 캐릭터를 raycast에서 제외한다.
local function collectGroundRaycastExcludes(): { Instance }
	local excludes: { Instance } = {}
	for _, folder in modelFolders do
		table.insert(excludes, folder)
	end
	for _, plr in Players:GetPlayers() do
		if plr.Character then
			table.insert(excludes, plr.Character :: Instance)
		end
	end
	return excludes
end

--- character 자신만 제외하고 그 위치에서 바로 아래로 raycast한 결과를 "이 근방의 신뢰 가능한
--- 지면 Y"로 쓴다. 플레이어는 실제로 지면에 서 있는 상태이므로(장식물 위에 떠 있지 않음) 이
--- 값을 Area의 raycast 결과를 검증하는 기준으로 사용할 수 있다.
local function playerGroundYReference(character: Model): number?
	local hitY = ModelGroundSnap.raycastGroundY(character:GetPivot().Position, { character })
	return hitY
end

--- baseExcludes로 raycast한 결과가 referenceY와 GROUND_Y_TOLERANCE_STUDS 이내면 그대로 채택.
--- 아니면(장식물 등 엉뚱한 표면을 맞힌 것으로 간주) 그 히트 Instance를 제외 목록에 추가해
--- 재시도한다. MAX_GROUND_RETRIES회를 넘기면 referenceY를 그대로 반환(최소한 "하늘에 떠 있는"
--- 최악의 경우는 방지).
local function findValidatedGroundY(position: Vector3, referenceY: number, baseExcludes: { Instance }): number
	local excludes = table.clone(baseExcludes)
	for _ = 1, MAX_GROUND_RETRIES do
		local hitY, hitInstance = ModelGroundSnap.raycastGroundY(position, excludes)
		if not hitY then
			break
		end
		if math.abs(hitY - referenceY) <= GROUND_Y_TOLERANCE_STUDS then
			return hitY
		end
		if not hitInstance then
			break
		end
		table.insert(excludes, hitInstance)
	end
	return referenceY
end

--- AreaRadius(반지름) 기준 UFO Scale. 지름(radius*2)이 UFO_SCALE_REFERENCE_DIAMETER_STUDS(16
--- studs)일 때 Scale=1이 되도록 선형 비례한다.
local function ufoScaleForAreaRadius(radius: number): number
	local diameter = radius * 2
	return diameter / UFO_SCALE_REFERENCE_DIAMETER_STUDS
end

--- radius의 Area에 스폰되는 UFO가 실제로 차지하는 수평 반경(스터드) + 겹침 방지 여유분의 절반.
--- ufoBaseRadius를 못 구했으면(템플릿 없음 등) 여유분만 반환해 겹침 방지 로직이 최소한의
--- 간격은 보장하도록 한다.
local function ufoVisualRadiusForArea(radius: number): number
	local base = ufoBaseRadius or 0
	return base * ufoScaleForAreaRadius(radius) + UFO_OVERLAP_PADDING_STUDS / 2
end

--- UFO를 최종 위치보다 UFO_DROP_IN_OFFSET_STUDS 위에 배치하고 Beam을 안 보이는 상태(Transparency=1)로
--- 스폰한다. 실제 하강/Beam Fade/PetMarkerArea 생성은 호출부가 이 함수의 반환값(ufo, beam, 최종
--- pivot)으로 playUfoAppearSequence를 실행해 처리한다 — 이 함수 자체는 애니메이션을 재생하지 않는다.
local function spawnUfoAtArea(area: Area, character: Model): (Model?, BasePart?, CFrame?)
	if not ufoTemplate then
		return nil
	end

	local ufo = (ufoTemplate :: Model):Clone()
	ufo.Name = "PetMarkUfo"
	ufo.Parent = Workspace
	ufo:PivotTo(CFrame.new(area.center))

	local scaleValue = ufoScaleForAreaRadius(area.radius)
	local scaleOk, scaleErr = pcall(function()
		ufo:ScaleTo(scaleValue)
	end)
	if not scaleOk then
		warn("[SpeechBubbleManager] UFO 스케일 적용 실패:", scaleErr)
	end

	-- Beam(UFO.Parts.Model.Beam)의 착지 범위를 이 Area의 AreaRadius에 맞춘다. ScaleTo가 이미
	-- 키워둔 Size를 덮어써야 하므로 ScaleTo 이후에 적용한다. Y(빔 길이)는 건드리지 않음.
	local beam: BasePart? = nil
	local beamCandidate = ufo:FindFirstChild("Beam", true)
	if beamCandidate and beamCandidate:IsA("BasePart") then
		local diameter = area.radius * 2
		beamCandidate.Size = Vector3.new(diameter, beamCandidate.Size.Y, diameter)
		-- 등장 연출: UFO가 다 내려오고 나서야 Beam이 보여야 하므로, 템플릿의 기본값과 무관하게
		-- 항상 안 보이는 상태로 시작한다.
		beamCandidate.Transparency = 1
		beam = beamCandidate
	end

	if RunService:IsStudio() then
		local characterPos = character:GetPivot().Position
		local flatOffset = Vector3.new(area.center.X - characterPos.X, 0, area.center.Z - characterPos.Z)
		local centerDist = flatOffset.Magnitude
		local ufoRadius = ufoVisualRadiusForArea(area.radius)
		print(
			string.format(
				"[SpeechBubbleManager][DEBUG] UFO Scale=%.3f (AreaRadius=%.1f) 플레이어-중심 거리=%.1f studs, 플레이어-표면 거리=%.1f studs",
				scaleValue,
				area.radius,
				centerDist,
				centerDist - ufoRadius
			)
		)
	end

	-- ufo 자신을 제외 목록에 반드시 포함해야 한다 — 이미 area.center에 배치된 상태라, 제외하지
	-- 않으면 이 raycast가 진짜 지면보다 먼저 ufo 자신의 몸(BoundingBox 등)을 맞혀 자기 키만큼
	-- 위로 스냅되는(=공중에 뜨는) 결과가 나온다.
	local excludes = collectGroundRaycastExcludes()
	table.insert(excludes, ufo)

	local referenceY = playerGroundYReference(character) or character:GetPivot().Position.Y
	local groundY = findValidatedGroundY(area.center, referenceY, excludes)

	-- 최종 위치가 아니라 그보다 UFO_DROP_IN_OFFSET_STUDS 위에 먼저 배치한다 — 여기서 최종 pivot을
	-- 계산해두면(현재 배치는 순수 이동이라 delta만큼 그대로 빼면 됨), 호출부가 그 최종 pivot으로
	-- 하강 Tween을 재생할 수 있다.
	ModelGroundSnap.placeModelBottomAtY(ufo, groundY + UFO_DROP_IN_OFFSET_STUDS)
	local finalPivot = ufo:GetPivot() - Vector3.new(0, UFO_DROP_IN_OFFSET_STUDS, 0)

	return ufo, beam, finalPivot
end

--- UFO 사전 안내와 같은 위치(area.center)에, 그 Area에서 프리뷰로 찾은 대상 건물의 실측 높이를
--- 반영한 지면 마커(PetMarkerArea)를 스폰한다. AreaRadius는 area.radius(건물 탐색 반경)를 그대로
--- 대응시키고, AreaHeight는 buildingHeightStuds(대상 건물의 실측 높이)를 그대로 대응시킨다 —
--- 두 속성 모두 PetMarkerAreaVisualSync.attach()가 GetAttributeChangedSignal로 구독해 즉시
--- 반영한다(ServerStorage.PetMarkerArea는 Rojo로 동기화되지 않는 Studio 전용 프리팹이라, 그 안에
--- Script를 심는 대신 이 ModuleScript를 직접 호출해 연동한다).
local function spawnPetMarkerAreaAtArea(area: Area, buildingHeightStuds: number, character: Model): Model?
	if not petMarkerAreaTemplate then
		return nil
	end

	local marker = (petMarkerAreaTemplate :: Model):Clone()
	marker.Name = "PetMarkerArea"
	marker.Parent = Workspace

	-- UFO와 동일한 지면 검증 로직(장식물 오탐 방지)을 재사용해 area.center 바로 아래 지면 Y를 구한다.
	local excludes = collectGroundRaycastExcludes()
	table.insert(excludes, marker)
	local referenceY = playerGroundYReference(character) or character:GetPivot().Position.Y
	local groundY = findValidatedGroundY(area.center, referenceY, excludes)
	marker:PivotTo(CFrame.new(area.center.X, groundY, area.center.Z))

	marker:SetAttribute("AreaRadius", area.radius)
	if buildingHeightStuds > 0 then
		marker:SetAttribute("AreaHeight", buildingHeightStuds)
	end

	PetMarkerAreaVisualSync.attach(marker)

	return marker
end

local function easeOutQuad(t: number): number
	return 1 - (1 - t) * (1 - t)
end

--- Model 전체를 startPivot -> endPivot으로 duration초에 걸쳐 부드럽게 이동시킨다. TweenService의
--- WorldPivot 프로퍼티 트윈이 이 프로젝트 환경에서는 재생되지 않는 게 실측 확인돼(Model에 프로퍼티
--- 테이블 트윈이 안 먹음), RunService.Heartbeat로 매 프레임 직접 PivotTo를 호출해 보간한다.
--- 도중에 model이 파괴되면(Parent가 nil이 되면) 즉시 중단한다.
local function tweenModelPivot(model: Model, startPivot: CFrame, endPivot: CFrame, duration: number)
	if duration <= 0 then
		if model.Parent then
			model:PivotTo(endPivot)
		end
		return
	end

	local elapsed = 0
	while model.Parent and elapsed < duration do
		local dt = RunService.Heartbeat:Wait()
		elapsed = math.min(elapsed + dt, duration)
		model:PivotTo(startPivot:Lerp(endPivot, easeOutQuad(elapsed / duration)))
	end
end

--- UFO 등장 연출 전체를 담당하는 비동기 시퀀스(task.spawn으로 실행): 하강(0.5초) -> Beam Fade(0.3초)
--- -> PetMarkerArea 생성 순서로 진행한다. 프리뷰 단계(t=35초)는 "후보 스캔~마킹 사이 yield 없음"
--- 불변식(모듈 상단 주석)의 적용 대상이 아니므로 비동기로 처리해도 안전하다.
---
--- 도중에 ufo가 파괴되거나(디버그 재입력 등으로 사이클이 취소됨) markerAreasOut이 더 이상
--- pendingPetMarkerAreasByUserId[userId]가 가리키는 테이블이 아니게 되면(새 사이클이 이미 시작됨)
--- 조용히 중단한다 — 고아 PetMarkerArea가 생기는 것을 막기 위함.
local function playUfoAppearSequence(
	ufo: Model,
	beam: BasePart,
	finalPivot: CFrame,
	displayArea: Area,
	buildingHeightStuds: number,
	character: Model,
	userId: number,
	markerAreasOut: { Model }
)
	local startPivot = ufo:GetPivot()
	tweenModelPivot(ufo, startPivot, finalPivot, UFO_DROP_IN_DURATION)
	if not ufo.Parent then
		return
	end

	local fadeTween = TweenService:Create(beam, UFO_BEAM_FADE_TWEEN_INFO, { Transparency = UFO_BEAM_VISIBLE_TRANSPARENCY })
	fadeTween:Play()
	-- Tween.Completed는 Enum.TweenStatus가 아니라 Enum.PlaybackState로 발화한다(취소 시 Cancelled).
	if fadeTween.Completed:Wait() ~= Enum.PlaybackState.Completed then
		return
	end

	if pendingPetMarkerAreasByUserId[userId] ~= markerAreasOut then
		return
	end

	local marker = spawnPetMarkerAreaAtArea(displayArea, buildingHeightStuds, character)
	if marker then
		table.insert(markerAreasOut, marker)
	end
end

--- t = MarkStartTime-AreaNoticeTime(35초): 이 player에 대해 Area 선정 + 프리뷰 UFO/PetMarkerArea
--- 스폰 + 사전 안내를 수행한다(runAreaNoticePhase 본체 + debugSpawnRandomUfoTrio가 공유).
local function runAreaNoticePhaseForPlayer(player: Player)
	local character = player.Character
	if not character then
		return
	end
	if levelOf(player) >= MAX_PLAYER_LEVEL then
		-- 2.3/7.1: Lv.9 도달 플레이어는 이후 Area/그룹을 생성하지 않는다.
		return
	end

	local position = character:GetPivot().Position
	local areas = PetMarkAreaSelector.computeAreas(position, levelOf(player), PetMarkConfig, modelFolders)
	cachedAreasByUserId[player.UserId] = areas

	-- 1단계: 프리뷰 탐색만 먼저 전부 돌려 대상 건물을 확정한다(마킹 없음, 순수 조회). 이 건물은
	-- PetMarkerArea의 AreaHeight를 그 실측 높이로 연동하기 위해 보관한다.
	local previews: { { area: Area, model: Model } } = {}
	for _, area in areas do
		local preview = PetMarkAreaSelector.selectBuildingForArea(area, levelOf(player), modelFolders, PetMarkConfig)
		if preview then
			table.insert(previews, { area = area, model = preview.model })
		end
	end

	-- 2단계: 실제 UFO 비주얼 반경(AreaRadius 기반)으로 겹침을 푼다. 이 결과는 UFO의 "표시
	-- 위치"에만 쓰고 p.area.center에는 절대 반영하지 않는다 — area.center는 40초 실제 마킹
	-- (selectBuildingForArea)의 탐색 기준점이기도 해서, 여기서 밀린 위치를 되먹임하면 UFO가
	-- 실제로 보이는 자리와 전혀 다른 곳에서 건물이 마킹되는 결과가 나온다(겹침 방지는 순수
	-- 시각적 문제이므로 게임플레이 탐색 위치를 건드릴 이유가 없음).
	local overlapItems: { { center: Vector3, radius: number } } = {}
	for _, p in previews do
		table.insert(overlapItems, { center = p.area.center, radius = ufoVisualRadiusForArea(p.area.radius) })
	end
	PetMarkAreaSelector.resolveVisualOverlaps(overlapItems)
	PetMarkAreaSelector.enforceMinSpawnDistance(overlapItems, position, levelOf(player), PetMarkConfig)
	PetMarkAreaSelector.resolveVisualOverlaps(overlapItems)

	-- 겹침 해소/최소 스폰 거리 강제 과정에서 표시 위치가 아레나 벽 밖(장외 영역)까지 밀려날 수
	-- 있으므로, 최종적으로 벽 안쪽에 머물도록 클램프한다. p.area(게임플레이 탐색 좌표)는 이미
	-- computeAreas 단계에서 경계 안임이 보장돼 있어 여기선 건드리지 않는다.
	for _, item in overlapItems do
		local clamped = ArenaBounds.clampCircleInside(item.center, item.radius)
		item.center = Vector3.new(clamped.X, item.center.Y, clamped.Z)
	end

	-- 3단계: 겹침 해소된 "표시 위치"로 UFO 스폰(p.area 자체는 건드리지 않음). PetMarkerArea는 UFO
	-- 등장 연출(하강 -> Beam Fade)이 끝난 뒤에야 생성된다(playUfoAppearSequence, 비동기) — AreaRadius는
	-- p.area.radius(건물 탐색 반경)에 대응시키며 AreaHeight는 이 프리뷰 건물(p.model)의 실측
	-- 높이(studs)에 연동한다. ufos/markerAreas는 아래 비동기 시퀀스가 안전하게 채워 넣을 수 있도록
	-- 루프 전에 미리 등록해둔다(참조 동일성으로 "그 사이 사이클이 갱신됐는지" 판별하기 위함).
	local ufos: { Model } = {}
	local markerAreas: { Model } = {}
	pendingUfosByUserId[player.UserId] = ufos
	pendingPetMarkerAreasByUserId[player.UserId] = markerAreas

	for i, p in previews do
		local displayArea: Area = { center = overlapItems[i].center, radius = p.area.radius }
		local ufo, beam, finalPivot = spawnUfoAtArea(displayArea, character)
		if ufo then
			table.insert(ufos, ufo)

			-- 공격판정용 투명 콜라이더(예: 세로로 큰 히트박스)는 실제 건물 높이가 아니므로 제외하고
			-- 측정한다(setupBubble과 동일 기준). 보이는 파츠가 없으면 기존 방식으로 폴백.
			local buildingExtents = ModelWorldExtents.computeVisible(p.model) or ModelWorldExtents.compute(p.model)

			if beam and finalPivot then
				task.spawn(
					playUfoAppearSequence,
					ufo,
					beam,
					finalPivot,
					displayArea,
					buildingExtents.sizeY,
					character,
					player.UserId,
					markerAreas
				)
			else
				-- Beam 템플릿이 없는 등 예외 상황 — 연출 없이 기존처럼 즉시 마커를 생성한다.
				local marker = spawnPetMarkerAreaAtArea(displayArea, buildingExtents.sizeY, character)
				if marker then
					table.insert(markerAreas, marker)
				end
			end
		end
	end

	areaNoticeEvent:FireClient(player, areas)
end

--- t = MarkStartTime-AreaNoticeTime(35초): Area 선정 + 프리뷰 UFO 스폰 + 사전 안내(전체 플레이어).
local function runAreaNoticePhase()
	if #modelFolders == 0 then
		return
	end
	for _, player in Players:GetPlayers() do
		runAreaNoticePhaseForPlayer(player)
	end
end

--- t = MarkStartTime(40초): 이 player에 대해 프리뷰 UFO 제거 + 실제 건물 마킹 + 그룹 생성을
--- 수행한다(runMarkSpawnPhase 본체 + debugSpawnRandomUfoTrio가 공유).
local function runMarkSpawnPhaseForPlayer(player: Player)
	local userId = player.UserId
	clearPendingUfos(userId)
	clearPendingPetMarkerAreas(userId)

	local areas = cachedAreasByUserId[userId]
	cachedAreasByUserId[userId] = nil
	if not areas or #areas == 0 or #modelFolders == 0 then
		return
	end

	local markers: { Model } = {}
	for _, area in areas do
		-- 실제 마킹: 이 시점 최신 레벨 사용(4.1). 후보 스캔~부착 사이 yield 없음(불변식 유지).
		local selection = PetMarkAreaSelector.selectBuildingForArea(area, levelOf(player), modelFolders, PetMarkConfig)
		if selection then
			setupBubble(selection.model)
			table.insert(markers, selection.model)
			markerOwnerByModel[selection.model] = userId
		end
	end

	if #markers > 0 then
		-- 50초 주기 > 10초 구출 윈도우이므로 통상 겹치지 않지만, 방어적으로 이전 그룹 정리.
		clearGroup(userId)
		groupsByUserId[userId] = { markers = markers, expireThread = nil }
		groupsByUserId[userId].expireThread = scheduleGroupExpiry(userId)
	end
end

--- t = MarkStartTime(40초): 프리뷰 UFO 제거 + 실제 건물 마킹 + 그룹 생성(전체 플레이어).
local function runMarkSpawnPhase()
	for _, player in Players:GetPlayers() do
		runMarkSpawnPhaseForPlayer(player)
	end
end

--- 전역 고정 사이클. StageManager.StageStartedAt 기준 절대 시각으로 계산해 누적 오차 없이
--- t=35,40,85,90...(초)에 각각 runAreaNoticePhase/runMarkSpawnPhase를 실행한다.
local function runGlobalCycle()
	while typeof(StageManager.StageStartedAt) ~= "number" do
		if GameManager.State.CurrentPhase == "Ended" then
			return
		end
		task.wait(0.5)
	end

	local startedAt = StageManager.StageStartedAt :: number
	local period = PetMarkConfig.MarkStartTime + PetMarkConfig.RescueDuration
	local cycleIndex = 0

	while true do
		if GameManager.State.CurrentPhase == "Ended" then
			break
		end

		-- 이번 사이클의 시작 시각(t=0,50,100...) 전까지는 대기한다 — 이게 없으면 직전 사이클의
		-- RescueDuration FireAllClients 직후 루프가 곧바로 다음 바퀴로 넘어가면서 "MarkStartTime"
		-- 이벤트를 실제 사이클 시작(=이전 RescueDuration이 끝나는 시점)보다 10초(RescueDuration)나
		-- 이르게 쏴버려, 클라이언트의 RescueDuration 카운트다운(HUD)이 시작하자마자 바로 다음
		-- MarkStartTime 이벤트에 덮여써 IconPet이 사실상 노출되지 않는 문제가 있었다.
		local cycleStartAt = startedAt + cycleIndex * period
		local waitCycleStart = cycleStartAt - os.clock()
		if waitCycleStart > 0 then
			task.wait(waitCycleStart)
		end
		if GameManager.State.CurrentPhase == "Ended" then
			break
		end

		-- 이번 사이클의 실제 마킹 시각(t=40)을 미리 계산해, "우주선 등장까지" 카운트다운(HUD)이
		-- 이 사이클 시작 시점부터 정확한 남은 시간으로 출발하게 한다(디버그 재정렬로 startedAt이
		-- 바뀌어도 여기서 다시 계산하므로 항상 실제 스케줄과 일치한다).
		local markAt = startedAt + PetMarkConfig.MarkStartTime + cycleIndex * period
		petTimerPhaseEvent:FireAllClients("MarkStartTime", math.max(0, markAt - os.clock()))

		local noticeAt = startedAt + (PetMarkConfig.MarkStartTime - PetMarkConfig.AreaNoticeTime) + cycleIndex * period
		local waitNotice = noticeAt - os.clock()
		if waitNotice > 0 then
			task.wait(waitNotice)
		end
		if GameManager.State.CurrentPhase == "Ended" then
			break
		end
		runAreaNoticePhase()

		local waitMark = markAt - os.clock()
		if waitMark > 0 then
			task.wait(waitMark)
		end
		if GameManager.State.CurrentPhase == "Ended" then
			break
		end
		runMarkSpawnPhase()

		local rescueEndAt = markAt + PetMarkConfig.RescueDuration
		petTimerPhaseEvent:FireAllClients("RescueDuration", math.max(0, rescueEndAt - os.clock()))

		cycleIndex += 1
	end
end

--- 전역 사이클을 최초 1회만 시작한다(idempotent). init()/startForPlayer 양쪽에서 호출된다.
local function beginCycleOnce()
	if cycleStarted then
		return
	end
	cycleStarted = true
	globalCycleThread = task.spawn(runGlobalCycle)
end

--- 스튜디오 디버그 스폰(X키) 전용: 메인(전역) 쿨타임을 "지금이 AreaNoticeTime 시작 시점"이 되도록
--- 재정렬하고, 이미 돌고 있는 runGlobalCycle 스레드를 취소한 뒤 그 새 기준 시각으로 다시 시작한다.
--- 이게 없으면 디버그로 즉시 띄운 프리뷰와, 원래 스케줄대로 흘러가던 전역 사이클의 다음 발화가
--- 타이밍상 겹쳐서 같은 플레이어에게 UFO/PetMarkerArea가 중복으로(예: 6개) 생기고, 뒤에 생긴 쪽은
--- pendingUfosByUserId/pendingPetMarkerAreasByUserId 추적을 뒤이은 사이클에 뺏겨 애니메이션 중간에
--- 멈춘 것처럼 보이는 문제가 있었다.
---
--- 재정렬 후에는 (재시작된) 전역 사이클 자신이 AreaNoticeTime 뒤에 모든 플레이어를 대상으로 실제
--- 마킹(runMarkSpawnPhase)을 수행하므로, 디버그 진입점이 스스로 마킹을 또 예약할 필요가 없다.
local function restartGlobalCycleForDebug()
	if globalCycleThread then
		task.cancel(globalCycleThread)
	end
	StageManager.StageStartedAt = os.clock() - (PetMarkConfig.MarkStartTime - PetMarkConfig.AreaNoticeTime)
	globalCycleThread = task.spawn(runGlobalCycle)
end

--- 스튜디오 전용 테스트 진입점: 이 player를 트리거로, 모든 플레이어의 기존 프리뷰 UFO/PetMarkerArea/
--- 그룹을 전부 정리한 뒤 메인(전역) 쿨타임만 재정렬한다(restartGlobalCycleForDebug). 별도로
--- runAreaNoticePhaseForPlayer를 직접 호출하지 않는다 — 재정렬된 시각 기준으로는 노티스 시점이
--- "지금"이라 재시작된 전역 사이클 자신이 곧바로 프리뷰를 스폰한다. 스폰 경로가 메인 플로우
--- 하나뿐이라 치트와 메인 사이클이 겹쳐 UFO가 중복(예: 3+3=6개)으로 뜨는 문제가 원천적으로 없다.
function SpeechBubbleManager.debugSpawnRandomUfoTrio(player: Player)
	if not RunService:IsStudio() then
		return
	end
	if not (#modelFolders > 0 and ufoTemplate) then
		warn("[SpeechBubbleManager] init 미완료/실패 상태 — 디버그 스폰 스킵")
		return
	end

	-- 모든 플레이어의 기존 프리뷰/그룹을 정리한다 — 곧 전역 사이클이 모든 플레이어에게 새 프리뷰를
	-- 스폰하므로, 이 player만 정리하면 다른 플레이어의 낡은 프리뷰가 그대로 남을 수 있다.
	for _, plr in Players:GetPlayers() do
		clearPendingUfos(plr.UserId)
		clearPendingPetMarkerAreas(plr.UserId)
		clearGroup(plr.UserId)
	end

	restartGlobalCycleForDebug()
	print(
		string.format(
			"[SpeechBubbleManager] 디버그: %s 트리거 — 메인 쿨타임 재정렬, 전역 사이클이 즉시 프리뷰 스폰 후 %d초 뒤 실제 마킹",
			player.Name,
			PetMarkConfig.AreaNoticeTime
		)
	)
end

function SpeechBubbleManager.init(stageMap: Instance?)

	print("[SpeechBubbleManager] init 시작")

	local resolvedStageMap = stageMap or Workspace:FindFirstChild("StageMap")
	if not resolvedStageMap then
		warn("[SpeechBubbleManager] StageMap 없음 — 말풍선 동적 생성 비활성화")
		return
	end

	for _, child in resolvedStageMap:GetChildren() do
		if child.Name == "Model" then
			table.insert(modelFolders, child)
		end
	end
	if #modelFolders == 0 then
		warn("[SpeechBubbleManager] StageMap.Model 없음 — 말풍선 동적 생성 비활성화")
	end

	template = ServerStorage:FindFirstChild(TEMPLATE_NAME)
	if not template then
		warn("[SpeechBubbleManager] ServerStorage." .. TEMPLATE_NAME .. " 없음 — 말풍선 동적 생성 비활성화")
	end

	ufoTemplate = ServerStorage:FindFirstChild(UFO_TEMPLATE_NAME)
	if not ufoTemplate then
		warn("[SpeechBubbleManager] ServerStorage." .. UFO_TEMPLATE_NAME .. " 없음 — Area 프리뷰 UFO 비활성화")
	else
		-- ufoTemplate은 ServerStorage에 Scale=1 기준으로 보관되므로, 여기서 측정한 수평 반경에
		-- ufoScaleForAreaRadius(area.radius)를 곱하면 그 Area UFO의 실제 비주얼 반경이 나온다.
		local extents = ModelWorldExtents.compute(ufoTemplate :: Model)
		ufoBaseRadius = math.max(extents.sizeX, extents.sizeZ) / 2
	end

	petMarkerAreaTemplate = ServerStorage:FindFirstChild(PET_MARKER_AREA_TEMPLATE_NAME)
	if not petMarkerAreaTemplate then
		warn("[SpeechBubbleManager] ServerStorage." .. PET_MARKER_AREA_TEMPLATE_NAME .. " 없음 — Area 프리뷰 지면 마커 비활성화")
	end

	-- 무거운 맵에서 init()이 실제로 끝났는지, 끝났다면 어떤 부품이 빠졌는지 항상 남긴다 — 위
	-- 개별 warn들은 서버 시작 시점에만 찍혀서 나중에 로그를 스크롤해 올라가야 하지만, 이건 init()
	-- 호출 시점 그대로 결과 요약이라 "펫마킹이 안 된다"는 제보를 받았을 때 바로 원인을 좁힐 수 있다.
	print(
		string.format(
			"[SpeechBubbleManager] init 완료: StageMap=%s Model=%d개 SpeechBubbleTemplate=%s UFO=%s PetMarkerArea=%s",
			resolvedStageMap:GetFullName(),
			#modelFolders,
			tostring(template ~= nil),
			tostring(ufoTemplate ~= nil),
			tostring(petMarkerAreaTemplate ~= nil)
		)
	)

	-- init()이 끝나기 전에 이미 startForPlayer가 호출됐었다면(예: init.server.luau에서
	-- SpeechBubbleManager.init()보다 stageGameplayStartEvent 연결이 먼저 이뤄져 있어서, 그 사이
	-- yield(task.wait 등) 도중 카운트다운이 끝난 플레이어가 있었던 경우) 그 요청을 여기서 대신
	-- 처리한다. 이게 없으면 그 세션 내내 전역 사이클이 영영 시작되지 않는다(cycleStarted가
	-- true로 세팅될 기회 자체가 없었기 때문).
	if pendingCycleStart and #modelFolders > 0 and template then
		pendingCycleStart = false
		print("[SpeechBubbleManager] init 완료 — 예약돼 있던 사이클 시작 요청을 지금 처리")
		beginCycleOnce()
	end
end

--- stageGameplayStartEvent가 해당 플레이어의 카운트다운 종료로 발동될 때 호출.
--- 전역 사이클은 최초 1회 호출될 때만 시작한다(idempotent).
function SpeechBubbleManager.startForPlayer(player: Player)
	if not (#modelFolders > 0 and template) then
		warn("[SpeechBubbleManager] init 미완료 상태 — 사이클 시작을 init 완료 후로 예약:", player.Name)
		pendingCycleStart = true
		return
	end

	beginCycleOnce()
end

Players.PlayerRemoving:Connect(function(player: Player)
	local userId = player.UserId
	cachedAreasByUserId[userId] = nil
	clearPendingUfos(userId)
	clearPendingPetMarkerAreas(userId)
	-- 진행 중인 그룹(이미 마킹된 SpeechBubbleGui)은 공용 오브젝트(7.2)이므로 정리하지 않고
	-- 다른 플레이어가 계속 파괴/클레임할 수 있도록 남겨둔다.
end)

return SpeechBubbleManager
