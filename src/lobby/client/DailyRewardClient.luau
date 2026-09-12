--[[
	로비 클라이언트: 7일 출석 보상
	- 수령 가능 시 DailyRewardPopup 자동 오픈
	- UI_Badge / BadgeId="DailyReward" 배지 표시
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DailyRewardPopup = require(script.Parent.popup.DailyRewardPopup)
local LobbyNotificationBadge = require(script.Parent.LobbyNotificationBadge)

local BADGE_ID_DAILY_REWARD = "DailyReward"

local DailyRewardClient = {}

local GET_SNAPSHOT_REMOTE_NAME = "GetDailyRewardSnapshot"

local initialized = false
local autoPopupAttempted = false

type RewardSnapshot = {
	hasClaimable: boolean?,
}

local function fetchSnapshot(): RewardSnapshot?
	local remote = ReplicatedStorage:FindFirstChild(GET_SNAPSHOT_REMOTE_NAME)
	if not remote or not remote:IsA("RemoteFunction") then
		remote = ReplicatedStorage:WaitForChild(GET_SNAPSHOT_REMOTE_NAME, 15)
	end
	if not remote or not remote:IsA("RemoteFunction") then
		warn("[DailyRewardClient] GetDailyRewardSnapshot 없음")
		return nil
	end

	local ok, result = pcall(function()
		return (remote :: RemoteFunction):InvokeServer()
	end)
	if not ok then
		warn("[DailyRewardClient] GetDailyRewardSnapshot 실패:", result)
		return nil
	end
	if typeof(result) ~= "table" then
		return nil
	end
	return result :: RewardSnapshot
end

function DailyRewardClient.refreshNotification()
	local snapshot = fetchSnapshot()
	if snapshot then
		LobbyNotificationBadge.setVisible(BADGE_ID_DAILY_REWARD, snapshot.hasClaimable == true)
	end
	return snapshot
end

local function tryAutoPopup()
	if autoPopupAttempted then
		return
	end
	autoPopupAttempted = true

	local snapshot = DailyRewardClient.refreshNotification()
	if snapshot and snapshot.hasClaimable == true then
		DailyRewardPopup.open()
	end
end

function DailyRewardClient.init()
	if initialized then
		return
	end
	initialized = true

	task.defer(tryAutoPopup)
	print("[DailyRewardClient] 초기화 완료")
end

return DailyRewardClient
