local CameraZoomModule = {}

local GameSettings = require(script.Parent.Parent.Config.GameSettings)
local ScaleModule = require(script.Parent.ScaleModule)

local BASE_DISTANCE = GameSettings.Camera.BaseDistance
local DISTANCE_PER_SCALE = GameSettings.Camera.DistancePerScale

function CameraZoomModule.getCharacterScale(character: Model): number
	return ScaleModule.getCharacterScale(character)
end

function CameraZoomModule.getFixedDistance(scale: number): number
	return BASE_DISTANCE + (scale - 1) * DISTANCE_PER_SCALE
end

function CameraZoomModule.setFixedZoom(player: Player, scale: number): number
	local distance = CameraZoomModule.getFixedDistance(scale)
	if distance >= player.CameraMaxZoomDistance then
		player.CameraMaxZoomDistance = distance
		player.CameraMinZoomDistance = distance
	else
		player.CameraMinZoomDistance = distance
		player.CameraMaxZoomDistance = distance
	end
	return distance
end

function CameraZoomModule.setupForPlayer(player: Player, getScale: (() -> number)?)
	local function onCharacterAdded(character: Model)
		task.wait(0.5)
		local scale = (getScale and getScale()) or CameraZoomModule.getCharacterScale(character)
		local distance = CameraZoomModule.setFixedZoom(player, scale)
		print(string.format("[CameraZoomModule] %s 스케일: %.1f, 고정 카메라 거리: %.1f", player.Name, scale, distance))
	end

	player.CharacterAdded:Connect(onCharacterAdded)

	if player.Character then
		task.wait(0.5)
		onCharacterAdded(player.Character)
	end
end

return CameraZoomModule
