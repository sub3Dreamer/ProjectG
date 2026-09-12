local PlaceManager = {}

local TeleportService = game:GetService("TeleportService")
local PlaceIds = require(script.Parent.Parent.Config.PlaceIds)

function PlaceManager.teleportToStage(player: Player, stageNumber: number): boolean
	local placeId = PlaceIds.Stages[stageNumber]
	if not placeId or placeId == 0 then
		warn("[PlaceManager] 존재하지 않는 스테이지:", stageNumber)
		return false
	end

	print("[PlaceManager]", player.Name, "→ 스테이지", stageNumber, "텔레포트 시도")

	local success, err = pcall(function()
		TeleportService:Teleport(placeId, player)
	end)

	if not success then
		warn("[PlaceManager] 텔레포트 실패:", err)
		task.delay(2, function()
			PlaceManager.teleportToStage(player, stageNumber)
		end)
		return false
	end

	return true
end

function PlaceManager.teleportToLobby(player: Player): boolean
	if PlaceIds.Lobby == 0 then
		warn("[PlaceManager] 로비 PlaceId가 설정되지 않았습니다")
		return false
	end

	print("[PlaceManager]", player.Name, "→ 로비 텔레포트 시도")

	local success, err = pcall(function()
		TeleportService:Teleport(PlaceIds.Lobby, player)
	end)

	if not success then
		warn("[PlaceManager] 로비 텔레포트 실패:", err)
		task.delay(2, function()
			PlaceManager.teleportToLobby(player)
		end)
		return false
	end

	return true
end

function PlaceManager.getCurrentPlaceType(): (string, number?)
	local currentPlaceId = game.PlaceId

	if currentPlaceId == PlaceIds.Lobby then
		return "Lobby", nil
	end

	for stageNum, stageId in PlaceIds.Stages do
		if currentPlaceId == stageId then
			return "Stage", stageNum
		end
	end

	return "Unknown", nil
end

return PlaceManager
