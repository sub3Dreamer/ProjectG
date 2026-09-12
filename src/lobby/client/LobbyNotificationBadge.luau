--[[
	로비 알림 배지 (범용)

	Studio: Notification Frame 에
		Tag       = UI_Badge
		Attribute = BadgeId (string)  — 예: "DailyReward"

	Luau:
		LobbyNotificationBadge.setVisible("DailyReward", true)
		LobbyNotificationBadge.registerProvider("DailyReward", fn) + refresh("DailyReward")
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local LobbyNotificationBadge = {}

local UI_BADGE_TAG = "UI_Badge"
local BADGE_ID_ATTR = "BadgeId"

export type BadgeProvider = () -> boolean

local initialized = false
local badgesById: { [string]: GuiObject } = {}
local providers: { [string]: BadgeProvider } = {}

local function readBadgeId(inst: Instance): string?
	local raw = inst:GetAttribute(BADGE_ID_ATTR)
	if typeof(raw) ~= "string" or raw == "" then
		return nil
	end
	return raw
end

local function isUnderLocalPlayerGui(inst: Instance): boolean
	local player = Players.LocalPlayer
	if not player then
		return false
	end
	local playerGui = player:FindFirstChild("PlayerGui")
	return playerGui ~= nil and inst:IsDescendantOf(playerGui)
end

local function unbindBadgeId(badgeId: string, inst: Instance)
	if badgesById[badgeId] == inst then
		badgesById[badgeId] = nil
	end
end

local function bindBadge(inst: Instance)
	if not inst:IsA("GuiObject") then
		return
	end
	if not isUnderLocalPlayerGui(inst) then
		return
	end

	local badgeId = readBadgeId(inst)
	if not badgeId then
		warn("[LobbyNotificationBadge] BadgeId 없음:", inst:GetFullName())
		return
	end

	if badgesById[badgeId] and badgesById[badgeId] ~= inst then
		warn(
			"[LobbyNotificationBadge] BadgeId 중복:",
			badgeId,
			badgesById[badgeId]:GetFullName(),
			"→",
			inst:GetFullName()
		)
	end

	badgesById[badgeId] = inst :: GuiObject

	inst.Destroying:Connect(function()
		unbindBadgeId(badgeId, inst)
	end)
end

local function scanExistingBadges()
	for _, inst in CollectionService:GetTagged(UI_BADGE_TAG) do
		bindBadge(inst)
	end
end

function LobbyNotificationBadge.getBadge(badgeId: string): GuiObject?
	local badge = badgesById[badgeId]
	if badge and badge.Parent then
		return badge
	end
	badgesById[badgeId] = nil
	return nil
end

function LobbyNotificationBadge.setVisible(badgeId: string, visible: boolean)
	local badge = LobbyNotificationBadge.getBadge(badgeId)
	if badge then
		badge.Visible = visible
	end
end

function LobbyNotificationBadge.registerProvider(badgeId: string, provider: BadgeProvider)
	providers[badgeId] = provider
end

function LobbyNotificationBadge.unregisterProvider(badgeId: string)
	providers[badgeId] = nil
end

function LobbyNotificationBadge.refresh(badgeId: string)
	local provider = providers[badgeId]
	if not provider then
		return
	end
	LobbyNotificationBadge.setVisible(badgeId, provider())
end

function LobbyNotificationBadge.refreshAll()
	for badgeId in providers do
		LobbyNotificationBadge.refresh(badgeId)
	end
end

function LobbyNotificationBadge.init()
	if initialized then
		return
	end
	initialized = true

	scanExistingBadges()

	CollectionService:GetInstanceAddedSignal(UI_BADGE_TAG):Connect(bindBadge)
	CollectionService:GetInstanceRemovedSignal(UI_BADGE_TAG):Connect(function(inst: Instance)
		local badgeId = readBadgeId(inst)
		if badgeId then
			unbindBadgeId(badgeId, inst)
		end
	end)

	print("[LobbyNotificationBadge] 초기화 완료")
end

return LobbyNotificationBadge
