--[[
	로비 클라이언트: 일일 미션
	- 수령 가능 시 UI_Badge / BadgeId="Mission" 배지 표시
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LobbyNotificationBadge = require(script.Parent.LobbyNotificationBadge)

local BADGE_ID_MISSION = "Mission"
local GET_SNAPSHOT_REMOTE_NAME = "GetMissionSnapshot"

local MissionClient = {}

local initialized = false

type MissionSnapshot = {
	hasClaimable: boolean?,
}

local function fetchSnapshot(): MissionSnapshot?
	local remote = ReplicatedStorage:FindFirstChild(GET_SNAPSHOT_REMOTE_NAME)
	if not remote or not remote:IsA("RemoteFunction") then
		remote = ReplicatedStorage:WaitForChild(GET_SNAPSHOT_REMOTE_NAME, 15)
	end
	if not remote or not remote:IsA("RemoteFunction") then
		warn("[MissionClient] GetMissionSnapshot 없음")
		return nil
	end

	local ok, result = pcall(function()
		return (remote :: RemoteFunction):InvokeServer()
	end)
	if not ok then
		warn("[MissionClient] GetMissionSnapshot 실패:", result)
		return nil
	end
	if typeof(result) ~= "table" then
		return nil
	end
	return result :: MissionSnapshot
end

function MissionClient.refreshNotification()
	local snapshot = fetchSnapshot()
	if snapshot then
		LobbyNotificationBadge.setVisible(BADGE_ID_MISSION, snapshot.hasClaimable == true)
	end
	return snapshot
end

function MissionClient.init()
	if initialized then
		return
	end
	initialized = true

	task.defer(MissionClient.refreshNotification)
	print("[MissionClient] 초기화 완료")
end

return MissionClient
