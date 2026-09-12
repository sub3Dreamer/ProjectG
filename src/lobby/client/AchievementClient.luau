--[[
	로비 클라이언트: 업적
	- 수령 가능 시 UI_Badge / BadgeId="Achievement" 배지 표시
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LobbyNotificationBadge = require(script.Parent.LobbyNotificationBadge)

local BADGE_ID_ACHIEVEMENT = "Achievement"
local GET_SNAPSHOT_REMOTE_NAME = "GetAchievementSnapshot"

local AchievementClient = {}

local initialized = false

type AchievementSnapshot = {
	hasClaimable: boolean?,
}

local function fetchSnapshot(): AchievementSnapshot?
	local remote = ReplicatedStorage:FindFirstChild(GET_SNAPSHOT_REMOTE_NAME)
	if not remote or not remote:IsA("RemoteFunction") then
		remote = ReplicatedStorage:WaitForChild(GET_SNAPSHOT_REMOTE_NAME, 15)
	end
	if not remote or not remote:IsA("RemoteFunction") then
		warn("[AchievementClient] GetAchievementSnapshot 없음")
		return nil
	end

	local ok, result = pcall(function()
		return (remote :: RemoteFunction):InvokeServer()
	end)
	if not ok then
		warn("[AchievementClient] GetAchievementSnapshot 실패:", result)
		return nil
	end
	if typeof(result) ~= "table" then
		return nil
	end
	return result :: AchievementSnapshot
end

function AchievementClient.refreshNotification()
	local snapshot = fetchSnapshot()
	if snapshot then
		LobbyNotificationBadge.setVisible(BADGE_ID_ACHIEVEMENT, snapshot.hasClaimable == true)
	end
	return snapshot
end

function AchievementClient.init()
	if initialized then
		return
	end
	initialized = true

	task.defer(AchievementClient.refreshNotification)
	print("[AchievementClient] 초기화 완료")
end

return AchievementClient
