--[[
	로컬 플레이어 캐릭터(R6/R15) 스폰 시 idle/walk/run 애니를 Animator에 미리 LoadAnimation.
	기본 Animate가 첫 이동 때 에셋을 받느라 걷기 모션이 늦게 붙는 현상 완화.
	AnimationId는 캐릭터 Animate 스크립트 하위 idle/walk/run 폴더를 읽음.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local GameSettings = require(script.Parent.Parent.Config.GameSettings)
local LocomotionWalkAnim = require(script.Parent.LocomotionWalkAnim)

local LocomotionAnimPreload = {}

local PRELOAD_STATE_FOLDER_NAMES = { "idle", "walk", "run" }
local ANIMATE_WAIT_SEC = 10
local ANIMATOR_POLL_INTERVAL_SEC = 0.05
local ANIMATOR_POLL_MAX_ATTEMPTS = 40

local initialized = false
local tracksByCharacter: { [Model]: { AnimationTrack } } = {}

local function collectLocomotionAnimations(animate: Instance): { Animation }
	local list: { Animation } = {}
	local seen: { [Animation]: boolean } = {}

	for _, folderName in PRELOAD_STATE_FOLDER_NAMES do
		local folder = animate:FindFirstChild(folderName)
		if not folder then
			continue
		end
		for _, desc in folder:GetDescendants() do
			if desc:IsA("Animation") and desc.AnimationId ~= "" and not seen[desc] then
				seen[desc] = true
				table.insert(list, desc)
			end
		end
	end

	return list
end

local function waitForAnimator(humanoid: Humanoid): Animator?
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end
	for _ = 1, ANIMATOR_POLL_MAX_ATTEMPTS do
		task.wait(ANIMATOR_POLL_INTERVAL_SEC)
		animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			return animator
		end
	end
	return nil
end

function LocomotionAnimPreload.preloadForCharacter(character: Model)
	if not character.Parent then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		humanoid = character:WaitForChild("Humanoid", ANIMATE_WAIT_SEC) :: Humanoid?
	end
	if not humanoid then
		return
	end

	local animate = character:FindFirstChild("Animate")
	if not animate then
		animate = character:WaitForChild("Animate", ANIMATE_WAIT_SEC)
	end
	if not animate then
		return
	end

	LocomotionWalkAnim.applyWalkAnimationIds(character)

	local animator = waitForAnimator(humanoid)
	if not animator then
		return
	end

	local animations = collectLocomotionAnimations(animate)
	if #animations == 0 then
		return
	end

	local tracks: { AnimationTrack } = {}
	for _, anim in animations do
		local ok, track = pcall(function()
			return animator:LoadAnimation(anim)
		end)
		if ok and track then
			table.insert(tracks, track)
		end
	end

	if #tracks > 0 then
		tracksByCharacter[character] = tracks
	end
end

function LocomotionAnimPreload.init()
	if RunService:IsServer() then
		return
	end
	if initialized then
		return
	end

	local cfg = GameSettings.CharacterStability
	if typeof(cfg) == "table" and cfg.LocomotionSystemsEnabled == false then
		return
	end

	initialized = true

	local player = Players.LocalPlayer

	local function onCharacter(character: Model)
		task.spawn(LocomotionAnimPreload.preloadForCharacter, character)
	end

	player.CharacterAdded:Connect(function(character: Model)
		tracksByCharacter[character] = nil
		onCharacter(character)
	end)

	if player.Character then
		task.defer(onCharacter, player.Character)
	end

	print("[LocomotionAnimPreload] 초기화 완료")
end

return LocomotionAnimPreload
