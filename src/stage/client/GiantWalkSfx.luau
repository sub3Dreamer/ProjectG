--[[
	XP 레벨 6 이상 거인 캐릭터 걷기 발소리 (모든 플레이어).
	걷기 애니 Footstep 마커 타이밍에 재생.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SoundManager = require(Shared.Managers.SoundManager)
local LocomotionWalkAnim = require(Shared.Utils.LocomotionWalkAnim)

local GiantWalkSfx = {}

local GIANT_MIN_XP_LEVEL = 6
local ANIMATE_WAIT_SEC = 10

local cleanupByCharacter: { [Model]: () -> () } = {}

local function getXpLevel(character: Model): number
	local lv = character:GetAttribute("XPLevel")
	if typeof(lv) == "number" and lv == lv and lv >= 1 then
		return math.floor(lv + 0.5)
	end
	return 1
end

local function playGiantFootstep(character: Model)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		SoundManager.playSfx(SoundManager.Sfx.GiantWalk, hrp)
	else
		SoundManager.playSfx(SoundManager.Sfx.GiantWalk)
	end
end

local function onFootstep(character: Model)
	if getXpLevel(character) < GIANT_MIN_XP_LEVEL then
		return
	end
	playGiantFootstep(character)
end

local function bindCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", ANIMATE_WAIT_SEC)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end

	character:WaitForChild("Animate", ANIMATE_WAIT_SEC)
	LocomotionWalkAnim.applyWalkAnimationIds(character)

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		for _ = 1, 40 do
			task.wait(0.05)
			animator = humanoid:FindFirstChildOfClass("Animator")
			if animator then
				break
			end
		end
	end
	if not animator then
		return
	end

	local previousCleanup = cleanupByCharacter[character]
	if previousCleanup then
		previousCleanup()
	end

	cleanupByCharacter[character] = LocomotionWalkAnim.bindFootstepMarkers(character, onFootstep)

	character.AncestryChanged:Connect(function(_, parent)
		if parent then
			return
		end
		local cleanup = cleanupByCharacter[character]
		if cleanup then
			cleanup()
			cleanupByCharacter[character] = nil
		end
	end)
end

local function onPlayer(plr: Player)
	plr.CharacterAdded:Connect(bindCharacter)
	if plr.Character then
		task.defer(bindCharacter, plr.Character)
	end
end

function GiantWalkSfx.init()
	for _, plr in Players:GetPlayers() do
		onPlayer(plr)
	end
	Players.PlayerAdded:Connect(onPlayer)
end

return GiantWalkSfx
