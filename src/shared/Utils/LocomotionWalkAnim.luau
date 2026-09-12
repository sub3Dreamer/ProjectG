--[[
	플레이어 걷기 AnimationId 매핑(R6/R15) 및 Footstep 마커 바인딩.
]]

local GameSettings = require(script.Parent.Parent.Config.GameSettings)

local LocomotionWalkAnim = {}

local FOOTSTEP_MARKER_NAME = "Footstep"

local function normalizeAssetId(animationId: string): string
	local digits = string.match(animationId, "%d+")
	return digits or animationId
end

local function getWalkAnimationConfig(): { R15: string?, R6: string? }?
	local cfg = GameSettings.CharacterStability
	if typeof(cfg) ~= "table" then
		return nil
	end
	local walkAnims = cfg.WalkAnimations
	if typeof(walkAnims) ~= "table" then
		return nil
	end
	return walkAnims
end

function LocomotionWalkAnim.getWalkAnimationId(humanoid: Humanoid): string?
	local walkAnims = getWalkAnimationConfig()
	if not walkAnims then
		warn("[LocomotionWalkAnim] WalkAnimationId 없음")
		return nil
	end
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return walkAnims.R6
	end
	return walkAnims.R15
end

function LocomotionWalkAnim.isWalkAnimationId(animationId: string, humanoid: Humanoid): boolean
	local configuredId = LocomotionWalkAnim.getWalkAnimationId(humanoid)
	if typeof(configuredId) ~= "string" or configuredId == "" then
		return false
	end
	return normalizeAssetId(animationId) == normalizeAssetId(configuredId)
end

function LocomotionWalkAnim.applyWalkAnimationIds(character: Model): boolean
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end

	local animId = LocomotionWalkAnim.getWalkAnimationId(humanoid)
	if typeof(animId) ~= "string" or animId == "" then
		return false
	end

	local animate = character:FindFirstChild("Animate")
	if not animate then
		return false
	end

	local walkFolder = animate:FindFirstChild("walk")
	if not walkFolder then
		return false
	end

	local applied = false
	for _, desc in walkFolder:GetDescendants() do
		if desc:IsA("Animation") then
			desc.AnimationId = animId
			applied = true
		end
	end

	return applied
end

function LocomotionWalkAnim.bindFootstepMarkers(
	character: Model,
	onFootstep: (character: Model) -> ()
): () -> ()
	local connections: { RBXScriptConnection } = {}
	local boundTracks: { [AnimationTrack]: boolean } = {}

	local function cleanup()
		for _, conn in connections do
			conn:Disconnect()
		end
		table.clear(connections)
		table.clear(boundTracks)
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return cleanup
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return cleanup
	end

	local function tryBindTrack(track: AnimationTrack)
		if boundTracks[track] then
			return
		end

		local animation = track.Animation
		if not animation then
			return
		end
		if not LocomotionWalkAnim.isWalkAnimationId(animation.AnimationId, humanoid) then
			return
		end

		boundTracks[track] = true

		local ok, markerSignal = pcall(function()
			return track:GetMarkerReachedSignal(FOOTSTEP_MARKER_NAME)
		end)
		if not ok or not markerSignal then
			return
		end

		table.insert(
			connections,
			markerSignal:Connect(function()
				onFootstep(character)
			end)
		)
	end

	local function bindPlayingWalkTracks()
		for _, track in animator:GetPlayingAnimationTracks() do
			tryBindTrack(track)
		end
	end

	table.insert(
		connections,
		animator.AnimationPlayed:Connect(function(track: AnimationTrack)
			tryBindTrack(track)
		end)
	)

	bindPlayingWalkTracks()

	return cleanup
end

return LocomotionWalkAnim