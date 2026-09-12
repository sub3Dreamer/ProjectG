local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(ReplicatedStorage.Shared.Managers.PopupManager)
local DataManager = require(Shared.Managers.DataManager)
local GameManager = require(Shared.Managers.GameManager)
local LeaderstatsHandler = require(Shared.Managers.LeaderstatsHandler)
local PlaceManager = require(Shared.Managers.PlaceManager)
local ScaleModule = require(Shared.Utils.ScaleModule)
local CameraZoomModule = require(Shared.Utils.CameraZoomModule)
local GameSettings = require(Shared.Config.GameSettings)
local StageManager = require(script.StageManager)
local StageHelper = require(Shared.Helpers.StageHelper)
local StageMapLoader = require(script.StageMapLoader)
local DamageableObjectStats = require(Shared.Utils.DamageableObjectStats)
local CombatHandler = require(script.CombatHandler)
local DamageableWorkspaceReset = require(script.DamageableWorkspaceReset)
local XpHandler = require(script.XpHandler)
local FeverFxCharacter = require(script.FeverFxCharacter)
local FeverGaugeHandler = require(script.FeverGaugeHandler)
local MissionHelper = require(Shared.Helpers.MissionHelper)
local AchievementHelper = require(Shared.Helpers.AchievementHelper)
local InventoryHelper = require(Shared.Helpers.InventoryHelper)
-- local EnemySpawnLocations = require(script.EnemySpawnLocations) -- 당분간 미사용
local StageArenaWalls = require(script.StageArenaWalls)
local ItemUseHandler = require(script.ItemUseHandler)
local SpeechBubbleManager = require(script.SpeechBubbleManager)
local PetManager = require(script.PetManager)

local placeType, stageNumber = PlaceManager.getCurrentPlaceType()
print("[Stage] 스테이지 서버 시작 - 스테이지:", stageNumber or "알 수 없음")

local stageTimeLimitSec = StageHelper.getTimeLimitSec(stageNumber)

local stageTimeLimitValue = Instance.new("IntValue")
stageTimeLimitValue.Name = "StageTimeLimitSec"
stageTimeLimitValue.Value = stageTimeLimitSec
stageTimeLimitValue.Parent = ReplicatedStorage
print("[Stage] 제한시간:", stageTimeLimitSec, "초 (", StageHelper.getDisplayName(stageNumber, "kr"), ")")

local scaleChangeEvent = Instance.new("RemoteEvent")
scaleChangeEvent.Name = "ScaleChangeEvent"
scaleChangeEvent.Parent = ReplicatedStorage

local scaleUpdateEvent = Instance.new("RemoteEvent")
scaleUpdateEvent.Name = "ScaleUpdateEvent"
scaleUpdateEvent.Parent = ReplicatedStorage

local levelUpVfxEvent = Instance.new("RemoteEvent")
levelUpVfxEvent.Name = "LevelUpVfxEvent"
levelUpVfxEvent.Parent = ReplicatedStorage

local feverFxToggleRequestEvent = Instance.new("RemoteEvent")
feverFxToggleRequestEvent.Name = "FeverFxToggleRequestEvent"
feverFxToggleRequestEvent.Parent = ReplicatedStorage

local feverGaugeSyncEvent = Instance.new("RemoteEvent")
feverGaugeSyncEvent.Name = "FeverGaugeSyncEvent"
feverGaugeSyncEvent.Parent = ReplicatedStorage

local returnToLobbyRequestEvent = Instance.new("RemoteEvent")
returnToLobbyRequestEvent.Name = "ReturnToLobbyRequestEvent"
returnToLobbyRequestEvent.Parent = ReplicatedStorage

local stageRetryRequestEvent = Instance.new("RemoteEvent")
stageRetryRequestEvent.Name = "StageRetryRequestEvent"
stageRetryRequestEvent.Parent = ReplicatedStorage

local stageClearedEvent = Instance.new("RemoteEvent")
stageClearedEvent.Name = "StageClearedEvent"
stageClearedEvent.Parent = ReplicatedStorage

local stageClearTestRequestEvent = Instance.new("RemoteEvent")
stageClearTestRequestEvent.Name = "StageClearTestRequestEvent"
stageClearTestRequestEvent.Parent = ReplicatedStorage

local stageGameplayStartEvent = Instance.new("RemoteEvent")
stageGameplayStartEvent.Name = "StageGameplayStartEvent"
stageGameplayStartEvent.Parent = ReplicatedStorage

local useItemRequestEvent = Instance.new("RemoteEvent")
useItemRequestEvent.Name = "UseItemRequestEvent"
useItemRequestEvent.Parent = ReplicatedStorage

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

-- 클라 VfxController가 CombatHandler.init 전에 연결할 수 있도록 조기 생성
ensureRemoteEvent("ExplodeVfxEvent")
ensureRemoteEvent("HitFxEvent")
ensureRemoteEvent("JudgementFxEvent")
ensureRemoteEvent("AttackEvent")
ensureRemoteEvent("RegisterAttackCooldown")
ensureRemoteEvent("TrampleAnimEvent")
ensureRemoteEvent("PetSavedEvent")
local debugSpawnUfoTrioRequestEvent = ensureRemoteEvent("DebugSpawnUfoTrioRequestEvent")

local loadedMap: Instance? = nil

stageGameplayStartEvent.OnServerEvent:Connect(function(player: Player)
	StageArenaWalls.ensureOnce()
	StageManager.startStage()
	SpeechBubbleManager.startForPlayer(player)
end)

--- 스튜디오에서만: 클라 C키 → 스테이지 클리어(테스트)
stageClearTestRequestEvent.OnServerEvent:Connect(function(_player: Player)
	print("[Stage Server] StageClearTestRequest 수신:", _player and _player.Name)
	if not RunService:IsStudio() then
		return
	end
	StageManager.clearStage()
end)

--- 스튜디오에서만: 클라 O키 → Area 기능으로 위치/범위 계산 후 랜덤 Tier로 UFO 3개 스폰(테스트)
debugSpawnUfoTrioRequestEvent.OnServerEvent:Connect(function(requestingPlayer: Player)
	if not RunService:IsStudio() then
		return
	end
	SpeechBubbleManager.debugSpawnRandomUfoTrio(requestingPlayer)
end)

returnToLobbyRequestEvent.OnServerEvent:Connect(function(requestingPlayer: Player)
	PlaceManager.teleportToLobby(requestingPlayer)
	print("[Stage] ReturnToLobbyRequestEvent: ", requestingPlayer.Name, "→ 로비 텔레포트")
end)

stageRetryRequestEvent.OnServerEvent:Connect(function(requestingPlayer: Player)
	if not stageNumber then
		warn("[Stage] StageRetry: 스테이지 번호를 알 수 없습니다")
		return
	end
	PlaceManager.teleportToStage(requestingPlayer, stageNumber)
	print("[Stage] StageRetryRequestEvent: ", requestingPlayer.Name, "→ 스테이지", stageNumber, "텔레포트")
end)

FeverGaugeHandler.init(feverGaugeSyncEvent)

local playerScales: { [number]: number } = {}

XpHandler.setApplyScaleCallback(function(player: Player, newLevel: number)
	local s = XpHandler.scaleForLevel(newLevel)
	local prevScale = playerScales[player.UserId] or GameSettings.Scale.PlayerScale
	playerScales[player.UserId] = s
	if player.Character then
		local ok, err = pcall(function()
			ScaleModule.setCharacterScale(player.Character, s)
		end)
		if not ok then
			warn("[Stage] 캐릭터 스케일 적용 실패:", err)
		end
		FeverFxCharacter.onPlayerScaled(player, s, playerScales)
		-- 스케일/이펙트 처리 후 WalkSpeed 한 번 더 맞춤 (레벨·Fever 속성과 동기화)
		if player.Character then
			ScaleModule.applyWalkSpeedForCharacter(player.Character)
		end
	end
	CameraZoomModule.setFixedZoom(player, s)
	scaleUpdateEvent:FireClient(player, s)
	if s > prevScale then
		levelUpVfxEvent:FireAllClients(player, s)
	end
	PetManager.onPlayerLevelUp(player, newLevel)
end)

-- GameScreenGui.TestPanel.Scale에서 레벨 ±1. 적용된 스케일은 setApplyScaleCallback에서 처리
scaleChangeEvent.OnServerEvent:Connect(function(player: Player, delta: number)
	if delta ~= 1 and delta ~= -1 then
		return
	end
	XpHandler.addLevelDelta(player, delta)
end)

GameManager.init()
DataManager.init()
MissionHelper.init()
AchievementHelper.init()
InventoryHelper.init()
LeaderstatsHandler.init()
XpHandler.init()

FeverFxCharacter.init(feverFxToggleRequestEvent, playerScales)
ItemUseHandler.init(useItemRequestEvent)

local function onPlayerAdded(player: Player)
	print("[Stage] 플레이어 접속:", player.Name)
	FeverGaugeHandler.onPlayerAdded(player)

	-- 유물 옵션(공격속도/이동속도/피버 게이지 획득 보너스)은 스테이지 중 변하지 않으므로
	-- 1회 계산 후 Attribute로 캐시 (클라이언트도 읽을 수 있어야 하고, 핫패스에서 매번 재계산 방지)
	player:SetAttribute("AttackSpeedUpPercent", GameManager.getPlayerOptionTotal(player, "AttackSpeedUp"))
	player:SetAttribute("MoveSpeedUpPercent", GameManager.getPlayerOptionTotal(player, "MoveSpeedUp"))
	player:SetAttribute("FeverGaugeGainBonusPercent", GameManager.getPlayerOptionTotal(player, "FeverGaugeGainBonus"))
	player:SetAttribute("XpGainBonusOnDestroyPercent", GameManager.getPlayerOptionTotal(player, "XpGainBonusOnDestroy"))
	player:SetAttribute("XpChargeOnLevelUpAmount", GameManager.getPlayerOptionTotal(player, "XpChargeOnLevelUp"))

	playerScales[player.UserId] = XpHandler.scaleForLevel(XpHandler.getLevel(player.UserId))
	ScaleModule.setupForPlayer(player, function()
		return playerScales[player.UserId] or GameSettings.Scale.PlayerScale
	end)
	CameraZoomModule.setupForPlayer(player, function()
		return playerScales[player.UserId] or GameSettings.Scale.PlayerScale
	end)
	StageManager.onPlayerJoined(player)

	scaleUpdateEvent:FireClient(player, playerScales[player.UserId] or GameSettings.Scale.PlayerScale)
end

Players.PlayerAdded:Connect(onPlayerAdded)

Players.PlayerRemoving:Connect(function(player: Player)
	FeverGaugeHandler.onPlayerRemoving(player)
	playerScales[player.UserId] = nil
end)

for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end

local mapInitStartClock = os.clock()

loadedMap = StageMapLoader.load()
StageManager.init(stageNumber)

local session = StageManager.getCurrentSession()
local difficulty = if session then session.difficulty else 2
local resolveRoot: Instance = loadedMap or Workspace:FindFirstChild("StageMap") or Workspace

local function resolveStageDamageables(): number
	return DamageableObjectStats.resolveAllInWorkspace(resolveRoot, difficulty)
end

local resolvedCount = resolveStageDamageables()
if resolvedCount == 0 then
	task.wait(0.25)
	resolvedCount = resolveStageDamageables()
end
print(
	"[Stage] Tier/HitPoint 런타임 resolve:",
	resolvedCount,
	"개 (difficulty=",
	difficulty,
	", root=",
	resolveRoot:GetFullName(),
	")"
)
if resolvedCount == 0 then
	DamageableObjectStats.warnUnresolvedDamageables(resolveRoot, difficulty)
end

CombatHandler.init()

-- task.spawn(f)는 f 자신이 먼저 yield하기 전까지는 그 자리에서 동기 실행되므로, f 내부에 yield가
-- 없으면 task.spawn으로 감싸도 호출부를 전혀 블로킹 없이 넘어가게 해주지 못한다(DamageableWorkspaceReset
-- .init()/EnemySpawnLocations.init() 둘 다 내부에 yield가 없어서 실제로 안 통했던 원인). 그래서
-- 무조건 task.wait()로 한 틱 미룬 뒤에 호출해 확실히 이 스레드를 먼저 반환시킨다.

-- Workspace 전체를 훑으며 Tier+HitPoint Model마다 Clone()까지 뜨는 무거운 스냅샷 작업이라(양이
-- 많은 맵일수록 비례해서 느려짐), 서버 부팅 순서를 막지 않도록 백그라운드로 돌린다.
-- restoreFromSnapshots()는 현재 어디서도 호출되지 않는 미사용 기능이라 완료 시점을 기다릴 소비자가
-- 없다 — 나중에 실제로 reset 기능이 붙으면 그때는 완료를 기다려야 할 수 있음.
task.spawn(function()
	task.wait()
	DamageableWorkspaceReset.init()
end)

-- EnemySpawnLocations 당분간 미사용 — 몬스터 스폰 기능 비활성화.
-- task.spawn(function()
-- 	task.wait()
-- 	EnemySpawnLocations.init()
-- end)

SpeechBubbleManager.init(loadedMap)
PetManager.init()

if RunService:IsStudio() then
	print(string.format("[Stage] 스테이지 초기화 완료 (맵 로드~여기까지 %.2f초)", os.clock() - mapInitStartClock))
end
