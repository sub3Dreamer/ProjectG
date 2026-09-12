--[[
	로비 클라이언트: 배틀패스
	- 수령 가능 시 UI_Badge / BadgeId="BattlePass" 배지 표시
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BattlePassHelper = require(Shared.Helpers.BattlePassHelper)
local LobbyNotificationBadge = require(script.Parent.LobbyNotificationBadge)

local BADGE_ID_BATTLE_PASS = "BattlePass"

local BattlePassClient = {}

local initialized = false

function BattlePassClient.refreshNotification()
	local snapshot = BattlePassHelper.fetchSnapshot()
	if snapshot then
		LobbyNotificationBadge.setVisible(
			BADGE_ID_BATTLE_PASS,
			BattlePassHelper.hasClaimableRewards(snapshot)
		)
	end
	return snapshot
end

function BattlePassClient.init()
	if initialized then
		return
	end
	initialized = true

	task.defer(BattlePassClient.refreshNotification)
	print("[BattlePassClient] 초기화 완료")
end

return BattlePassClient
