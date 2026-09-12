local LobbyManager = {}

local Players = game:GetService("Players")

function LobbyManager.init()
	print("[LobbyManager] 로비 매니저 초기화")
end

function LobbyManager.getPlayerCount(): number
	return #Players:GetPlayers()
end

return LobbyManager
