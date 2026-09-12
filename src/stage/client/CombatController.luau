local CombatController = {}

local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameSettings = require(Shared.Config.GameSettings)
local ScaleModule = require(Shared.Utils.ScaleModule)
local SoundManager = require(Shared.Managers.SoundManager)
local StageHUD = require(script.Parent.StageHUD)
local ObjectHpBar = require(script.Parent.ObjectHpBar)

local player = Players.LocalPlayer
local lastAttackTime = 0
local lastTrampleTime = 0

local function getFeverAttackCooldownMultiplier(character: Model?): number
	if not character or character:GetAttribute("FeverMode") ~= true then
		return 1
	end
	local fm = GameSettings.Combat.FeverMode
	if typeof(fm) ~= "table" then
		return 1
	end
	local m = fm.AttackCooldownMultiplier
	if typeof(m) == "number" and m == m and m > 0 then
		return m
	end
	return 1
end

local function getFeverAttackHitDelayMultiplier(character: Model?): number
	if not character or character:GetAttribute("FeverMode") ~= true then
		return 1
	end
	local fm = GameSettings.Combat.FeverMode
	if typeof(fm) ~= "table" then
		return 1
	end
	local m = fm.AttackHitDelayMultiplier
	if typeof(m) == "number" and m == m and m > 0 then
		return m
	end
	return 1
end

--- 유물 AttackSpeedUp 옵션 % 만큼 쿨다운/딜레이를 줄이는 배율 (서버가 onPlayerAdded에서 캐시한 Attribute 사용)
local function getAttackSpeedUpMultiplier(character: Model?): number
	if not character then
		return 1
	end
	local plr = Players:GetPlayerFromCharacter(character)
	if not plr then
		return 1
	end
	local percent = plr:GetAttribute("AttackSpeedUpPercent")
	if typeof(percent) ~= "number" or percent <= 0 then
		return 1
	end
	return 1 / (1 + percent / 100)
end

local function getCombatAnimationPlaybackSpeed(character: Model?): number
	local m = getFeverAttackCooldownMultiplier(character) * getAttackSpeedUpMultiplier(character)
	return 1 / m
end

local function getAutoTrampleCooldownSeconds(character: Model?): number
	local base = GameSettings.Combat.AutoTrampleCooldown or 0.8
	local ch = character or player.Character
	return base * getFeverAttackCooldownMultiplier(ch) * getAttackSpeedUpMultiplier(ch)
end

local function getAttackCooldownSeconds(): number
	local base = GameSettings.Combat.AttackCooldown
	return base * getFeverAttackCooldownMultiplier(player.Character) * getAttackSpeedUpMultiplier(player.Character)
end

local function getAttackHitDelaySeconds(): number
	local base = GameSettings.Combat.AttackHitDelay
	return base * getFeverAttackHitDelayMultiplier(player.Character) * getAttackSpeedUpMultiplier(player.Character)
end

-- Fever 시 쿨다운이 짧아진 비율만큼 공격·밟기 애니도 빠르게 (배율 = 1 / AttackCooldownMultiplier)
local function getAttackAnimationPlaybackSpeed(): number
	return getCombatAnimationPlaybackSpeed(player.Character)
end

local attackTracks: { AnimationTrack } = {}
local currentAttackIndex = 1

type StompState = { tracks: { AnimationTrack }, index: number }
local stompStateByCharacter: { [Model]: StompState } = {}
local feverTrackByCharacter: { [Model]: AnimationTrack } = {}
local locomotionSuppressConnByCharacter: { [Model]: RBXScriptConnection } = {}
local stompLocomotionWatchTokenByCharacter: { [Model]: number } = {}
local trampleMoveLockConn: RBXScriptConnection? = nil
local trampleMoveLockUntil = 0
local feverIntroLockConn: RBXScriptConnection? = nil
local feverIntroLockUntil = 0
local feverAnimationAssetsPreloaded = false

local DEBUG_HITBOX = false
local HOLD_ATTACK_POLL_SEC = 0.05
local ATTACK_BUTTON_NAMES = { "AttackButton", "BtnAttack", "AttackBtn" }

type ActiveTouchInfo = { holdStarted: boolean }
local activeTouches: { [InputObject]: ActiveTouchInfo } = {}
local joystickTouchIds: { [InputObject]: boolean } = {}
local boundThumbstickFrames: { [GuiObject]: boolean } = {}
local attackHoldDepth = 0
local attackButtonHoldDepth = 0
local attackHoldLoopActive = false

local function isJoystickTouch(touchInput: InputObject): boolean
	return joystickTouchIds[touchInput] == true
end

local function countActiveTouches(): number
	local n = 0
	for _ in activeTouches do
		n += 1
	end
	return n
end

local function isOnlyJoystickTouchActive(): boolean
	if countActiveTouches() ~= 1 then
		return false
	end
	for input in activeTouches do
		return joystickTouchIds[input] == true
	end
	return false
end

local function hasOtherJoystickTouch(exclude: InputObject): boolean
	for input in activeTouches do
		if input ~= exclude and joystickTouchIds[input] then
			return true
		end
	end
	return false
end

local function bindDynamicThumbstickFrame(frame: GuiObject)
	if boundThumbstickFrames[frame] then
		return
	end
	boundThumbstickFrames[frame] = true

	frame.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			joystickTouchIds[input] = true
		end
	end)
end

local function tryBindJoystickFromTouchGui(touchGui: Instance)
	if not touchGui:IsA("ScreenGui") then
		return
	end

	local function bindIfPresent(): boolean
		local controlFrame = touchGui:FindFirstChild("TouchControlFrame")
		if not controlFrame then
			return false
		end

		local thumbstickFrame = controlFrame:FindFirstChild("DynamicThumbstickFrame")
		if thumbstickFrame and thumbstickFrame:IsA("GuiObject") then
			bindDynamicThumbstickFrame(thumbstickFrame)
			return true
		end
		return false
	end

	if bindIfPresent() then
		return
	end

	touchGui.DescendantAdded:Connect(function(descendant)
		if descendant.Name == "DynamicThumbstickFrame" and descendant:IsA("GuiObject") then
			bindDynamicThumbstickFrame(descendant)
		end
	end)
end

local function setupJoystickTouchTracking(playerGui: PlayerGui)
	local existingTouchGui = playerGui:FindFirstChild("TouchGui")
	if existingTouchGui then
		tryBindJoystickFromTouchGui(existingTouchGui)
	end

	playerGui.ChildAdded:Connect(function(child)
		if child.Name == "TouchGui" then
			tryBindJoystickFromTouchGui(child)
		end
	end)
end

local function shouldStartTouchAttackHold(gameProcessed: boolean, touchInput: InputObject): boolean
	if countActiveTouches() >= 2 then
		-- 두 번째 손가락: 다른 손가락이 조이스틱일 때만 공격 홀드
		if isJoystickTouch(touchInput) then
			return false
		end
		return hasOtherJoystickTouch(touchInput)
	end
	if gameProcessed or isJoystickTouch(touchInput) then
		return false
	end
	return true
end

local function countActiveTouchHolds(): number
	local n = 0
	for _, info in activeTouches do
		if info.holdStarted then
			n += 1
		end
	end
	return n
end

local function reconcileAttackHoldDepth()
	local expectedDepth = attackButtonHoldDepth + countActiveTouchHolds()
	if attackHoldDepth > expectedDepth then
		attackHoldDepth = expectedDepth
	end
end

--- 활성 터치가 조이스틱 1개뿐이면 터치 공격 홀드·depth 정리
local function stopAttackHoldIfOnlyJoystickTouch()
	if not isOnlyJoystickTouchActive() then
		return
	end
	for _, info in activeTouches do
		info.holdStarted = false
	end
	reconcileAttackHoldDepth()
end

local function getCurrentScale(): number
	local character = player.Character
	if not character then
		return 1
	end
	return ScaleModule.getCharacterScale(character)
end

local function showDebugBox()
	if not DEBUG_HITBOX then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoidRootPart then
		return
	end

	local scale = getCurrentScale()
	local range = GameSettings.Combat.AttackRange * scale
	local boxScale = GameSettings.Combat.AttackBoxScale or Vector3.new(1, 1, 1)
	local offset = GameSettings.Combat.AttackOffset

	local box = Instance.new("Part")
	box.Size = Vector3.new(range, range, range) * boxScale
	box.CFrame = humanoidRootPart.CFrame * CFrame.new(offset) + humanoidRootPart.CFrame.LookVector * (range / 2)
	box.Anchored = true
	box.CanCollide = false
	box.Transparency = 0.7
	box.Color = Color3.fromRGB(255, 0, 0)
	box.Material = Enum.Material.Neon
	box.Parent = workspace

	task.delay(0.3, function()
		box:Destroy()
	end)
end

local function getAttackAnimationIds(humanoid: Humanoid): { string }
	local anims = GameSettings.Combat.AttackAnimations
	if typeof(anims) ~= "table" then
		return {}
	end
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return anims.R6 or {}
	end
	return anims.R15 or {}
end

local function getStompAnimationIds(humanoid: Humanoid): { string }
	local anims = GameSettings.Combat.StompAnimations
	if typeof(anims) ~= "table" then
		return {}
	end
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return anims.R6 or {}
	end
	return anims.R15 or {}
end

local function getFeverAnimationId(humanoid: Humanoid): string?
	local anims = GameSettings.Combat.FeverAnimation
	if typeof(anims) ~= "table" then
		return nil
	end
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return anims.R6
	end
	return anims.R15
end

local function getFeverAnimationInputLockSeconds(): number
	local cfg = GameSettings.Combat.FeverAnimation
	if typeof(cfg) == "table" and typeof(cfg.InputLockSeconds) == "number" and cfg.InputLockSeconds > 0 then
		return cfg.InputLockSeconds
	end
	return 1
end

local function getFeverAnimationDurationSeconds(): number
	local cfg = GameSettings.Combat.FeverAnimation
	if typeof(cfg) == "table" and typeof(cfg.DurationSeconds) == "number" and cfg.DurationSeconds > 0 then
		return cfg.DurationSeconds
	end
	return 1
end

local function collectFeverAnimationInstances(): { Animation }
	local cfg = GameSettings.Combat.FeverAnimation
	if typeof(cfg) ~= "table" then
		return {}
	end

	local seen: { [string]: boolean } = {}
	local list: { Animation } = {}
	for _, animId in { cfg.R6, cfg.R15 } do
		if typeof(animId) == "string" and animId ~= "" and not seen[animId] then
			seen[animId] = true
			local anim = Instance.new("Animation")
			anim.AnimationId = animId
			table.insert(list, anim)
		end
	end
	return list
end

local function preloadFeverAnimationAssets()
	if feverAnimationAssetsPreloaded then
		return
	end
	feverAnimationAssetsPreloaded = true

	local animations = collectFeverAnimationInstances()
	if #animations == 0 then
		return
	end

	pcall(function()
		ContentProvider:PreloadAsync(animations)
	end)
end

local function waitForAnimator(humanoid: Humanoid, timeoutSec: number): Animator?
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end

	local deadline = os.clock() + timeoutSec
	while os.clock() < deadline do
		task.wait(0.05)
		animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			return animator
		end
	end
	return nil
end

local function isFeverIntroLocked(): boolean
	return tick() < feverIntroLockUntil
end

local function suppressLocomotionTracks(humanoid: Humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	for _, track in animator:GetPlayingAnimationTracks() do
		local priority = track.Priority
		if priority == Enum.AnimationPriority.Idle or priority == Enum.AnimationPriority.Movement then
			track:Stop(0)
		end
	end
end

local function stopTrampleMoveLock()
	if trampleMoveLockConn then
		trampleMoveLockConn:Disconnect()
		trampleMoveLockConn = nil
	end
	trampleMoveLockUntil = 0
	local ch = player.Character
	if ch and not StageHUD.IsGameplayInputLocked then
		ScaleModule.applyWalkSpeedForCharacter(ch)
	end
end

--- 로컬 플레이어: 밟기 쿨다운 동안 이동 잠금 + idle/walk 애니 억제
local function startTrampleMoveLock(character: Model)
	if StageHUD.IsGameplayInputLocked then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	trampleMoveLockUntil = tick() + getAutoTrampleCooldownSeconds(character)
	humanoid.WalkSpeed = 0
	suppressLocomotionTracks(humanoid)

	if trampleMoveLockConn then
		return
	end

	trampleMoveLockConn = RunService.Heartbeat:Connect(function()
		if tick() >= trampleMoveLockUntil then
			stopTrampleMoveLock()
			return
		end
		if StageHUD.IsGameplayInputLocked or isFeverIntroLocked() then
			return
		end

		local ch = player.Character
		if not ch then
			return
		end

		local hum = ch:FindFirstChildOfClass("Humanoid")
		local hrp = ch:FindFirstChild("HumanoidRootPart")
		if hum then
			hum.WalkSpeed = 0
			suppressLocomotionTracks(hum)
		end
		if hrp and hrp:IsA("BasePart") then
			local vel = hrp.AssemblyLinearVelocity
			hrp.AssemblyLinearVelocity = Vector3.new(0, vel.Y, 0)
		end
	end)
end

local function stopFeverIntroLock()
	if feverIntroLockConn then
		feverIntroLockConn:Disconnect()
		feverIntroLockConn = nil
	end
	feverIntroLockUntil = 0
	local ch = player.Character
	if ch and not StageHUD.IsGameplayInputLocked then
		ScaleModule.applyWalkSpeedForCharacter(ch)
	end
end

--- 로컬 플레이어: 피버 시작 애니 중 이동 잠금 + idle/walk 애니 억제
local function startFeverIntroInputLock(character: Model)
	if character ~= player.Character then
		return
	end

	local lockSec = getFeverAnimationInputLockSeconds()
	feverIntroLockUntil = tick() + lockSec

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
		suppressLocomotionTracks(humanoid)
	end

	if feverIntroLockConn then
		return
	end

	feverIntroLockConn = RunService.Heartbeat:Connect(function()
		if tick() >= feverIntroLockUntil then
			stopFeverIntroLock()
			return
		end
		if StageHUD.IsGameplayInputLocked or isFeverIntroLocked() then
			return
		end

		local ch = player.Character
		if not ch then
			return
		end

		local hum = ch:FindFirstChildOfClass("Humanoid")
		local hrp = ch:FindFirstChild("HumanoidRootPart")
		if hum then
			hum.WalkSpeed = 0
			suppressLocomotionTracks(hum)
		end
		if hrp and hrp:IsA("BasePart") then
			local vel = hrp.AssemblyLinearVelocity
			hrp.AssemblyLinearVelocity = Vector3.new(0, vel.Y, 0)
		end
	end)
end

local function stopLocomotionSuppression(character: Model)
	local conn = locomotionSuppressConnByCharacter[character]
	if conn then
		conn:Disconnect()
		locomotionSuppressConnByCharacter[character] = nil
	end
end

local function startLocomotionSuppressionForStomp(character: Model, stompTrack: AnimationTrack)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	stopLocomotionSuppression(character)

	local token = (stompLocomotionWatchTokenByCharacter[character] or 0) + 1
	stompLocomotionWatchTokenByCharacter[character] = token

	suppressLocomotionTracks(humanoid)

	local heartbeatConn = RunService.Heartbeat:Connect(function()
		if not character.Parent or stompLocomotionWatchTokenByCharacter[character] ~= token then
			stopLocomotionSuppression(character)
			return
		end
		if not stompTrack.IsPlaying then
			stopLocomotionSuppression(character)
			return
		end
		suppressLocomotionTracks(humanoid)
	end)
	locomotionSuppressConnByCharacter[character] = heartbeatConn

	local stoppedConn: RBXScriptConnection
	stoppedConn = stompTrack.Stopped:Connect(function()
		stoppedConn:Disconnect()
		if stompLocomotionWatchTokenByCharacter[character] ~= token then
			return
		end
		stopLocomotionSuppression(character)
	end)
end

local function clearStompStateForCharacter(character: Model)
	stopLocomotionSuppression(character)
	if character == player.Character then
		stopTrampleMoveLock()
	end
	stompLocomotionWatchTokenByCharacter[character] = nil
	stompStateByCharacter[character] = nil
end

local function clearFeverStateForCharacter(character: Model)
	feverTrackByCharacter[character] = nil
	if character == player.Character then
		stopFeverIntroLock()
	end
end

local function watchCharacterStompCleanup(character: Model)
	character.AncestryChanged:Connect(function()
		if not character.Parent then
			clearStompStateForCharacter(character)
			clearFeverStateForCharacter(character)
		end
	end)
end

local function loadStompTracksForCharacter(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end

	local tracks: { AnimationTrack } = {}
	for _, animId in getStompAnimationIds(humanoid) do
		local anim = Instance.new("Animation")
		anim.AnimationId = animId
		local track = animator:LoadAnimation(anim)
		track.Looped = false
		track.Priority = Enum.AnimationPriority.Action
		table.insert(tracks, track)
	end

	stompStateByCharacter[character] = {
		tracks = tracks,
		index = 1,
	}
end

local function playTrampleStompOnCharacter(character: Model)
	if GameSettings.Combat.StompAnimationsEnabled == false then
		return
	end

	if not character.Parent then
		return
	end

	local state = stompStateByCharacter[character]
	if not state or #state.tracks == 0 then
		loadStompTracksForCharacter(character)
		state = stompStateByCharacter[character]
	end
	if not state or #state.tracks == 0 then
		return
	end

	for _, track in state.tracks do
		if track.IsPlaying then
			track:Stop(0)
		end
	end

	local track = state.tracks[state.index]
	track:AdjustSpeed(getCombatAnimationPlaybackSpeed(character))
	-- 로컬은 startTrampleMoveLock(쿨다운 전체)에서 idle/walk 억제. 원격은 밟기 애니 재생 중만.
	if character ~= player.Character then
		startLocomotionSuppressionForStomp(character, track)
	end
	track:Play()
	state.index = state.index % #state.tracks + 1
end

local function loadFeverTrackForCharacter(character: Model): AnimationTrack?
	local existing = feverTrackByCharacter[character]
	if existing then
		return existing
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end

	local animator = waitForAnimator(humanoid, 2)
	if not animator then
		return nil
	end

	local animId = getFeverAnimationId(humanoid)
	if typeof(animId) ~= "string" or animId == "" then
		return nil
	end

	local anim = Instance.new("Animation")
	anim.AnimationId = animId
	pcall(function()
		ContentProvider:PreloadAsync({ anim })
	end)

	local ok, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if not ok or not track then
		return nil
	end

	track.Looped = false
	track.Priority = Enum.AnimationPriority.Action
	feverTrackByCharacter[character] = track
	return track
end

local function preloadFeverTrackForCharacter(character: Model)
	if not character.Parent then
		return
	end

	preloadFeverAnimationAssets()

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	end
	if not humanoid then
		return
	end

	loadFeverTrackForCharacter(character)
end

local function scheduleFeverDrainAfterIntro(character: Model, track: AnimationTrack)
	if character ~= player.Character then
		return
	end

	local durationSec = getFeverAnimationDurationSeconds()
	local introDone = false
	local function onIntroDone()
		if introDone then
			return
		end
		introDone = true
		StageHUD.beginFeverDrainAfterIntro()
	end

	local stoppedConn: RBXScriptConnection?
	stoppedConn = track.Stopped:Connect(function()
		if stoppedConn then
			stoppedConn:Disconnect()
			stoppedConn = nil
		end
		onIntroDone()
	end)

	task.delay(durationSec, onIntroDone)
end

local function playFeverAnimation(character: Model)
	if not character.Parent then
		return
	end

	local track = feverTrackByCharacter[character]
	if not track then
		track = loadFeverTrackForCharacter(character)
	end
	if not track then
		if character == player.Character then
			StageHUD.beginFeverDrainAfterIntro()
		end
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		suppressLocomotionTracks(humanoid)
	end

	if track.IsPlaying then
		track:Stop(0)
	end
	track:Play()

	if character == player.Character then
		startFeverIntroInputLock(character)
		scheduleFeverDrainAfterIntro(character, track)
	end
end

local function bindFeverAnimationListener(character: Model)
	local wasActive = character:GetAttribute("FeverMode") == true

	character:GetAttributeChangedSignal("FeverMode"):Connect(function()
		local active = character:GetAttribute("FeverMode") == true
		if active and not wasActive then
			playFeverAnimation(character)
		end
		wasActive = active
	end)
end

local function hookPlayerFeverAnimation(plr: Player)
	plr.CharacterAdded:Connect(function(character: Model)
		clearFeverStateForCharacter(character)
		bindFeverAnimationListener(character)
		task.spawn(preloadFeverTrackForCharacter, character)
	end)
	if plr.Character then
		bindFeverAnimationListener(plr.Character)
		task.spawn(preloadFeverTrackForCharacter, plr.Character)
	end
end

local function loadAnimationTracks()
	attackTracks = {}
	currentAttackIndex = 1

	local character = player.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end

	for _, animId in getAttackAnimationIds(humanoid) do
		local anim = Instance.new("Animation")
		anim.AnimationId = animId
		local track = animator:LoadAnimation(anim)
		track.Looped = false
		track.Priority = Enum.AnimationPriority.Action
		table.insert(attackTracks, track)
	end
end

local function getHitboxCenter(): (CFrame?, number)
	local character = player.Character
	if not character then
		return nil, 1
	end

	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoidRootPart then
		return nil, 1
	end

	local scale = getCurrentScale()
	local range = GameSettings.Combat.AttackRange * scale
	local offset = GameSettings.Combat.AttackOffset
	local lookVector = humanoidRootPart.CFrame.LookVector

	return humanoidRootPart.CFrame * CFrame.new(offset) + lookVector * (range / 2), scale
end

local function getDamageableModelFromPart(part: BasePart): Model?
	local attrName = GameSettings.Combat.CurrentHitPointAttributeName or "CurrentHitPoint"
	local inst: Instance? = part
	while inst and inst ~= Workspace do
		if inst:IsA("Model") then
			local hp = inst:GetAttribute(attrName)
			if typeof(hp) == "number" and hp == hp and hp > 0 then
				return inst
			end
		end
		inst = inst.Parent
	end
	return nil
end

local function isDamageablePart(part: BasePart): boolean
	return getDamageableModelFromPart(part) ~= nil
end

local function collectDamageableOwnersInHitbox(boxCenter: CFrame, scale: number): { Model }
	local character = player.Character
	if not character then
		return {}
	end

	local range = GameSettings.Combat.AttackRange * scale
	local boxScale = GameSettings.Combat.AttackBoxScale or Vector3.new(1, 1, 1)
	local boxSize = Vector3.new(range, range, range) * boxScale

	local overlapParams = OverlapParams.new()
	overlapParams.FilterDescendantsInstances = { character }
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude

	local owners: { [Model]: boolean } = {}
	local list: { Model } = {}

	for _, part in Workspace:GetPartBoundsInBox(boxCenter, boxSize, overlapParams) do
		if part:IsA("BasePart") then
			local model = getDamageableModelFromPart(part)
			if model and not owners[model] then
				owners[model] = true
				table.insert(list, model)
			end
		end
	end

	return list
end

local function fireAttack()
	if StageHUD.IsGameplayInputLocked or isFeverIntroLocked() then
		return
	end

	showDebugBox()

	local hitboxCenter, scale = getHitboxCenter()

	local attackEvent = ReplicatedStorage:FindFirstChild("AttackEvent")
	if attackEvent and hitboxCenter then
		attackEvent:FireServer(hitboxCenter, scale)
	end

	if hitboxCenter and scale then
		for _, owner in collectDamageableOwnersInHitbox(hitboxCenter, scale) do
			ObjectHpBar.activate(owner)
		end
	end
end

local function isAnyAttackTrackPlaying(): boolean
	for _, t in attackTracks do
		if t.IsPlaying then
			return true
		end
	end
	return false
end

local function attack()
	if StageHUD.IsGameplayInputLocked or isFeverIntroLocked() then
		return
	end

	local now = tick()
	if now - lastAttackTime < getAttackCooldownSeconds() then
		return
	end
	if now - lastTrampleTime < getAutoTrampleCooldownSeconds(player.Character) then
		return
	end

	if #attackTracks == 0 then
		loadAnimationTracks()
	end

	-- 어택 모션이 아직 재생 중이면 입력 무시(트랙 블렌딩으로 모션이 작아지는 현상 방지).
	-- cooldown 통과 후에 검사하여, cooldown 자체는 기존대로 입력 차단을 유지.
	if isAnyAttackTrackPlaying() then
		return
	end

	lastAttackTime = now

	local registerCooldownEvent = ReplicatedStorage:FindFirstChild("RegisterAttackCooldown")
	if registerCooldownEvent and registerCooldownEvent:IsA("RemoteEvent") then
		registerCooldownEvent:FireServer()
	end

	if #attackTracks > 0 then
		local track = attackTracks[currentAttackIndex]
		local playSpeed = getAttackAnimationPlaybackSpeed()
		track:AdjustSpeed(playSpeed)
		track:Play()
		SoundManager.playSfx(SoundManager.Sfx.Swing)
		currentAttackIndex = currentAttackIndex % #attackTracks + 1
	end

	task.delay(getAttackHitDelaySeconds(), fireAttack)
end

local function stopAllAttackHold()
	attackHoldDepth = 0
	attackButtonHoldDepth = 0
end

local function startAttackHoldLoopIfNeeded()
	if attackHoldLoopActive then
		return
	end
	attackHoldLoopActive = true
	task.spawn(function()
		while attackHoldDepth > 0 do
			if isOnlyJoystickTouchActive() then
				stopAttackHoldIfOnlyJoystickTouch()
				break
			end
			if not StageHUD.IsGameplayInputLocked and not isFeverIntroLocked() then
				attack()
			end
			task.wait(HOLD_ATTACK_POLL_SEC)
		end
		attackHoldLoopActive = false
	end)
end

local function beginAttackHold()
	local wasZero = attackHoldDepth == 0
	attackHoldDepth += 1
	if wasZero then
		if not StageHUD.IsGameplayInputLocked and not isFeverIntroLocked() then
			attack()
		end
		startAttackHoldLoopIfNeeded()
	end
end

local function endAttackHold()
	if attackHoldDepth <= 0 then
		return
	end
	attackHoldDepth -= 1
end

local function isAttackHoldInput(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function bindAttackHoldButton(button: GuiButton)
	button.InputBegan:Connect(function(input: InputObject)
		if not isAttackHoldInput(input) then
			return
		end
		if StageHUD.IsGameplayInputLocked or isFeverIntroLocked() then
			return
		end
		beginAttackHold()
		attackButtonHoldDepth += 1
	end)
	button.InputEnded:Connect(function(input: InputObject)
		if not isAttackHoldInput(input) then
			return
		end
		if attackButtonHoldDepth > 0 then
			attackButtonHoldDepth -= 1
		end
		endAttackHold()
	end)
end

local function tryBindAttackButtons(root: Instance)
	for _, name in ATTACK_BUTTON_NAMES do
		local inst = root:FindFirstChild(name, true)
		if inst and inst:IsA("GuiButton") then
			bindAttackHoldButton(inst)
		end
	end
end

local function hasTargetInRange(): boolean
	local character = player.Character
	if not character then
		return false
	end

	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoidRootPart then
		return false
	end

	local scale = getCurrentScale()
	local range = GameSettings.Combat.AttackRange * scale
	local boxScale = GameSettings.Combat.AttackBoxScale or Vector3.new(1, 1, 1)
	local offset = GameSettings.Combat.AttackOffset
	local lookVector = humanoidRootPart.CFrame.LookVector

	local boxCenter = humanoidRootPart.CFrame * CFrame.new(offset) + lookVector * (range / 2)
	local boxSize = Vector3.new(range, range, range) * boxScale

	local overlapParams = OverlapParams.new()
	overlapParams.FilterDescendantsInstances = { character }
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude

	local parts = workspace:GetPartBoundsInBox(boxCenter, boxSize, overlapParams)
	for _, part in parts do
		if part:IsA("BasePart") and isDamageablePart(part) then
			return true
		end
	end
	return false
end

function CombatController.init()
	print("[CombatController] 전투 컨트롤러 초기화")

	task.spawn(preloadFeverAnimationAssets)

	local playerGui = player:WaitForChild("PlayerGui")
	local gameGui = playerGui:WaitForChild("GameScreenGui")
	tryBindAttackButtons(gameGui)
	setupJoystickTouchTracking(playerGui)

	UserInputService.WindowFocusReleased:Connect(stopAllAttackHold)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if StageHUD.IsGameplayInputLocked or isFeverIntroLocked() then
			return
		end

		if input.UserInputType == Enum.UserInputType.Touch then
			activeTouches[input] = {
				holdStarted = false,
			}

			-- DynamicThumbstickFrame.InputBegan이 먼저 joystickTouchIds를 채운 뒤 판정
			task.defer(function()
				local touchInfo = activeTouches[input]
				if not touchInfo or touchInfo.holdStarted then
					return
				end
				if shouldStartTouchAttackHold(gameProcessed, input) then
					touchInfo.holdStarted = true
					beginAttackHold()
				end
			end)
			return
		end

		if gameProcessed then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.KeyCode == Enum.KeyCode.F then
			beginAttackHold()
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.KeyCode == Enum.KeyCode.F then
			endAttackHold()
			return
		end

		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local touchInfo = activeTouches[input]
		if not touchInfo then
			return
		end

		if touchInfo.holdStarted then
			endAttackHold()
		end

		activeTouches[input] = nil
		joystickTouchIds[input] = nil
		stopAttackHoldIfOnlyJoystickTouch()
		reconcileAttackHoldDepth()
	end)

	task.spawn(function()
		while true do
			if not StageHUD.IsGameplayInputLocked and not isFeverIntroLocked() and StageHUD.IsAutoAttackEnabled and hasTargetInRange() then
				attack()
			end
			task.wait(0.1)
		end
	end)

	player.CharacterAdded:Connect(function(character: Model)
		stopAllAttackHold()
		stopTrampleMoveLock()
		stopFeverIntroLock()
		attackTracks = {}
		currentAttackIndex = 1
		lastAttackTime = 0
		lastTrampleTime = 0
		clearStompStateForCharacter(character)
		watchCharacterStompCleanup(character)
		character:WaitForChild("Humanoid", 5)
		task.defer(loadAnimationTracks)
		task.defer(preloadFeverTrackForCharacter, character)
	end)

	for _, plr in Players:GetPlayers() do
		hookPlayerFeverAnimation(plr)
		plr.CharacterAdded:Connect(watchCharacterStompCleanup)
		if plr.Character then
			watchCharacterStompCleanup(plr.Character)
		end
	end
	Players.PlayerAdded:Connect(function(plr: Player)
		hookPlayerFeverAnimation(plr)
		plr.CharacterAdded:Connect(watchCharacterStompCleanup)
	end)

	local trampleAnimEvent = ReplicatedStorage:WaitForChild("TrampleAnimEvent", 30)
	if trampleAnimEvent and trampleAnimEvent:IsA("RemoteEvent") then
		trampleAnimEvent.OnClientEvent:Connect(function(tramplingPlayer: Player)
			if typeof(tramplingPlayer) ~= "Instance" or not tramplingPlayer:IsA("Player") then
				return
			end
			if tramplingPlayer == player and isFeverIntroLocked() then
				return
			end
			local character = tramplingPlayer.Character
			if character then
				if tramplingPlayer == player then
					lastTrampleTime = tick()
					startTrampleMoveLock(character)
				end
				playTrampleStompOnCharacter(character)
			end
		end)
	else
		warn("[CombatController] TrampleAnimEvent not found — auto-trample stomp animations will not play")
	end

	print("[CombatController] 전투 컨트롤러 초기화 완료")
end

return CombatController
