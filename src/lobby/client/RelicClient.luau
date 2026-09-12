--[[
	로비 클라이언트: 유물
	- 레벨업 가능 유물 있을 때 UI_Badge / BadgeId="Relic" 배지 표시
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RelicHelper = require(Shared.Helpers.RelicHelper)
local LobbyNotificationBadge = require(script.Parent.LobbyNotificationBadge)

local BADGE_ID_RELIC = "Relic"

local RelicClient = {}

local initialized = false

function RelicClient.refreshNotification(progress: RelicHelper.RelicProgress?)
	local hasUpgradeable = RelicHelper.hasUpgradeableRelics(progress)
	LobbyNotificationBadge.setVisible(BADGE_ID_RELIC, hasUpgradeable)
	return hasUpgradeable
end

function RelicClient.init()
	if initialized then
		return
	end
	initialized = true

	task.defer(RelicClient.refreshNotification)
	print("[RelicClient] 초기화 완료")
end

return RelicClient
