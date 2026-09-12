--[[
	스테이지 시작 전 보스 인트로 카메라 (줌·포커스 연출).
	캐릭터/카메라 보스 방향 정렬은 StageStartBossFacing.apply()가 BossIntroCamera.play() 전에 처리.
	StreamingEnabled 환경: RequestStreamAroundAsync + PreloadAsync + 시각 준비 대기.
]]

local BossIntroCamera = {}

--- false면 play/beginPreload 즉시 스킵 (코드는 유지). 인게임 비활성화용.
BossIntroCamera.Enabled = true

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local StageBossLocator = require(script.Parent.StageBossLocator)
local StageStartBossFacing = require(script.Parent.StageStartBossFacing)
local BossIntroPopup = require(script.Parent.popup.BossIntroPopup)

local BOSS_VISUAL_READY_TIMEOUT_SEC = 5
local BOSS_VISUAL_READY_POLL_SEC = 0.1
local TRAVEL_TWEEN_SEC = 1
local PRE_FOCUS_WAIT_SEC = 2
local BOSS_FOCUS_SEC = 2
local MIN_BOSS_STANDOFF_STUDS = 5
local TRAVEL_TWEEN = TweenInfo.new(TRAVEL_TWEEN_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

local player = Players.LocalPlayer
local activeSerial = 0
local preloadStarted = false
local cachedBoss: Model? = nil
local cachedBossVisualReady = false

local function isBossVisuallyReady(boss: Model): boolean
	if not boss.Parent then
		return false
	end

	local hasVisiblePart = false
	for _, d in boss:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 1 then
			hasVisiblePart = true
			break
		end
	end
	if not hasVisiblePart then
		return false
	end

	local ok, _, size = pcall(function()
		return boss:GetBoundingBox()
	end)
	return ok and typeof(size) == "Vector3" and size.Y > 1
end

local function collectBossPreloadAssets(boss: Model): { Instance }
	local assets: { Instance } = {}
	for _, d in boss:GetDescendants() do
		if d:IsA("MeshPart") or d:IsA("Decal") or d:IsA("Texture") or d:IsA("SurfaceAppearance") or d:IsA("SpecialMesh") then
			table.insert(assets, d)
		end
	end
	return assets
end

local function requestStreamAroundBoss(boss: Model)
	local pos = boss:GetPivot().Position
	pcall(function()
		player:RequestStreamAroundAsync(pos)
	end)
end

local function preloadBossAssets(boss: Model)
	local assets = collectBossPreloadAssets(boss)
	if #assets == 0 then
		return
	end
	pcall(function()
		ContentProvider:PreloadAsync(assets)
	end)
end

--- 스트리밍·에셋 로드 후 보스 메시가 보일 때까지 대기. cancelCheck true면 중단.
local function prepareBossVisual(boss: Model, cancelCheck: (() -> boolean)?): boolean
	if isBossVisuallyReady(boss) then
		return true
	end

	requestStreamAroundBoss(boss)
	if cancelCheck and cancelCheck() then
		return false
	end

	preloadBossAssets(boss)
	if cancelCheck and cancelCheck() then
		return false
	end

	local deadline = os.clock() + BOSS_VISUAL_READY_TIMEOUT_SEC
	while os.clock() < deadline do
		if cancelCheck and cancelCheck() then
			return false
		end
		if isBossVisuallyReady(boss) then
			return true
		end
		task.wait(BOSS_VISUAL_READY_POLL_SEC)
	end

	if isBossVisuallyReady(boss) then
		return true
	end

	warn("[BossIntroCamera] 보스 시각 준비 타임아웃 — 인트로는 계속 진행")
	return false
end

--- startCf 각도 유지, 시선 축으로 보스 프레이밍 거리만큼 전진(줌인).
local function getZoomForwardStudsAlongRay(startCf: CFrame, boss: Model, camera: Camera): number?
	local bossLookAt, standOff, bossHeight = StageBossLocator.getFramingInfo(boss)
	local startPos = startCf.Position
	local lookVector = startCf.LookVector

	local depthAlongRay = (bossLookAt - startPos):Dot(lookVector)
	if depthAlongRay <= MIN_BOSS_STANDOFF_STUDS then
		return nil
	end

	local halfFov = math.rad(camera.FieldOfView * 0.5)
	local fovStandOff = (bossHeight * 0.7) / math.tan(halfFov)
	local desiredStandOff = math.max(standOff, fovStandOff)

	local forwardStuds = depthAlongRay - desiredStandOff
	return math.clamp(forwardStuds, 0, depthAlongRay - MIN_BOSS_STANDOFF_STUDS)
end

local function getZoomedInCFrame(fromCf: CFrame, forwardStuds: number): CFrame
	return fromCf * CFrame.new(0, 0, -forwardStuds)
end

local function tweenCameraCFrame(camera: Camera, target: CFrame)
	local tween = TweenService:Create(camera, TRAVEL_TWEEN, { CFrame = target })
	tween:Play()
	tween.Completed:Wait()
end

--- 연출 종료 후 기본 3인칭 pitch(플레이어 가슴 lookAt)로 복귀.
local function restoreCamera(character: Model, boss: Model?)
	if boss and StageStartBossFacing.snapCameraBehindPlayerFacingBoss(character, boss) then
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	camera.CameraType = Enum.CameraType.Custom
	if humanoid and humanoid.Parent then
		camera.CameraSubject = humanoid
	end
end

--- StageHUD.init 전에 호출하면 인트로 전에 보스 스트리밍·프리로드를 백그라운드로 시작.
function BossIntroCamera.beginPreload()
	if not BossIntroCamera.Enabled then
		return
	end
	if preloadStarted then
		return
	end
	preloadStarted = true

	task.spawn(function()
		local boss = StageBossLocator.waitForBoss()
		if not boss then
			return
		end
		cachedBoss = boss
		cachedBossVisualReady = prepareBossVisual(boss, nil)
	end)
end

--- 보스 인트로 연출 후 onComplete. 보스 없으면 즉시 onComplete.
function BossIntroCamera.play(onComplete: (() -> ())?)
	if not BossIntroCamera.Enabled then
		if onComplete then
			onComplete()
		end
		return
	end

	activeSerial += 1
	local serial = activeSerial

	local function finish()
		BossIntroPopup.close()
		if onComplete then
			onComplete()
		end
	end

	local function isCancelled(): boolean
		return serial ~= activeSerial
	end

	local character = player.Character
	if not character then
		finish()
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		finish()
		return
	end

	local boss = cachedBoss
	if not boss or not boss.Parent then
		boss = StageBossLocator.waitForBoss()
	end
	if not boss then
		warn("[BossIntroCamera] StageMap 직계 자식에서 StageBoss Model 없음 — 인트로 스킵")
		finish()
		return
	end
	cachedBoss = boss

	if not cachedBossVisualReady or not isBossVisuallyReady(boss) then
		prepareBossVisual(boss, isCancelled)
		if isCancelled() then
			finish()
			return
		end
	end
	cachedBossVisualReady = isBossVisuallyReady(boss)

	local camera = Workspace.CurrentCamera
	if not camera then
		finish()
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable
	local startCf = StageStartBossFacing.getFacingCameraCFrame(character, boss)
	if not startCf then
		restoreCamera(character, boss)
		finish()
		return
	end
	camera.CFrame = startCf

	task.wait(PRE_FOCUS_WAIT_SEC)
	if isCancelled() then
		restoreCamera(character, boss)
		finish()
		return
	end

	local forwardStuds = getZoomForwardStudsAlongRay(startCf, boss, camera)
	if forwardStuds and forwardStuds > 0.01 then
		tweenCameraCFrame(camera, getZoomedInCFrame(startCf, forwardStuds))
	else
		warn("[BossIntroCamera] 보스가 시선 밖이거나 너무 가까움 — 줌인 스킵")
	end

	BossIntroPopup.showBossName()

	if isCancelled() then
		restoreCamera(character, boss)
		finish()
		return
	end

	task.wait(BOSS_FOCUS_SEC)

	if isCancelled() or not boss.Parent then
		restoreCamera(character, boss)
		finish()
		return
	end

	BossIntroPopup.close()
	tweenCameraCFrame(camera, startCf)

	restoreCamera(character, boss)
	finish()
end

return BossIntroCamera
