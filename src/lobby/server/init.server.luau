local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
if not Shared then
	warn("[Lobby] Shared를 찾을 수 없습니다! Rojo 싱크를 확인하세요.")
	return
end

local PopupManager = require(ReplicatedStorage.Shared.Managers.PopupManager)
local DataManager = require(Shared.Managers.DataManager)
local GameManager = require(Shared.Managers.GameManager)
local LobbyManager = require(script.LobbyManager)
local RoomManager = require(script.RoomManager)
local PvpRoomManager = require(script.PvpRoomManager)
local PortalHandler = require(script.PortalHandler)
local LobbyPhysicsSetup = require(script.LobbyPhysicsSetup)
local DailyRewardHelper = require(Shared.Helpers.DailyRewardHelper)
local RelicHelper = require(Shared.Helpers.RelicHelper)
local MissionHelper = require(Shared.Helpers.MissionHelper)
local AchievementHelper = require(Shared.Helpers.AchievementHelper)
local ShopHelper = require(Shared.Helpers.ShopHelper)
local BattlePassHelper = require(Shared.Helpers.BattlePassHelper)
local InventoryHelper = require(Shared.Helpers.InventoryHelper)
local CostumeHelper = require(Shared.Helpers.CostumeHelper)

print("[Lobby] 로비 서버 시작")

GameManager.init()
DataManager.init()
DailyRewardHelper.init()
RelicHelper.init()
MissionHelper.init()
AchievementHelper.init()
ShopHelper.init()
BattlePassHelper.init()
InventoryHelper.init()
CostumeHelper.init()

local function onPlayerAdded(player: Player)
	print("[Lobby] 플레이어 접속:", player.Name)
end

Players.PlayerAdded:Connect(onPlayerAdded)

for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end

LobbyManager.init()
RoomManager.init()
PvpRoomManager.init()
LobbyPhysicsSetup.init()
PortalHandler.init()

print("[Lobby] 로비 초기화 완료")
