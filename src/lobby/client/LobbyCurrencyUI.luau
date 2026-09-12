--[[
	LobbyCurrencyUI (lobby client)

	LobbyScreenGui.CenterTop
		Gem.GemCnt   — DataManager CurrencyAttribute.Gem
		Gold.GoldCnt — DataManager CurrencyAttribute.Gold
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DataManager = require(Shared.Managers.DataManager)

local LobbyCurrencyUI = {}

local LOBBY_SCREEN_GUI_NAME = "LobbyScreenGui"
local CENTER_TOP_NAME = "CenterTop"

local initialized = false
local displayFrozen = false
local gemLabelRef: TextLabel? = nil
local goldLabelRef: TextLabel? = nil

local function formatCurrencyText(amount: number): string
	return tostring(math.max(0, math.floor(amount)))
end

local function refreshCurrencyLabels()
	if not gemLabelRef or not goldLabelRef then
		return
	end
	if displayFrozen then
		return
	end
	gemLabelRef.Text = formatCurrencyText(DataManager.getLocalGem())
	goldLabelRef.Text = formatCurrencyText(DataManager.getLocalGold())
end

function LobbyCurrencyUI.freezeDisplay()
	displayFrozen = true
end

function LobbyCurrencyUI.unfreezeAndRefresh()
	displayFrozen = false
	refreshCurrencyLabels()
end

local function findCurrencyLabels(lobbyGui: Instance): (TextLabel?, TextLabel?)
	local centerTop = lobbyGui:FindFirstChild(CENTER_TOP_NAME)
	if not centerTop then
		return nil, nil
	end

	local gemFrame = centerTop:FindFirstChild("Gem")
	local goldFrame = centerTop:FindFirstChild("Gold")
	local gemCnt = gemFrame and gemFrame:FindFirstChild("GemCnt")
	local goldCnt = goldFrame and goldFrame:FindFirstChild("GoldCnt")

	local gemLabel = if gemCnt and gemCnt:IsA("TextLabel") then gemCnt :: TextLabel else nil
	local goldLabel = if goldCnt and goldCnt:IsA("TextLabel") then goldCnt :: TextLabel else nil
	return gemLabel, goldLabel
end

local function bindCurrencyLabels(player: Player, gemLabel: TextLabel, goldLabel: TextLabel)
	gemLabelRef = gemLabel
	goldLabelRef = goldLabel

	local attrGem = DataManager.CurrencyAttribute.Gem
	local attrGold = DataManager.CurrencyAttribute.Gold

	player:GetAttributeChangedSignal(attrGem):Connect(refreshCurrencyLabels)
	player:GetAttributeChangedSignal(attrGold):Connect(refreshCurrencyLabels)
	refreshCurrencyLabels()
end

function LobbyCurrencyUI.init()
	if initialized then
		return
	end
	initialized = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local lobbyGui = playerGui:WaitForChild(LOBBY_SCREEN_GUI_NAME)

	local gemLabel, goldLabel = findCurrencyLabels(lobbyGui)
	if not gemLabel then
		warn("[LobbyCurrencyUI] CenterTop.Gem.GemCnt (TextLabel) 없음")
	end
	if not goldLabel then
		warn("[LobbyCurrencyUI] CenterTop.Gold.GoldCnt (TextLabel) 없음")
	end
	if not gemLabel or not goldLabel then
		return
	end

	bindCurrencyLabels(player, gemLabel, goldLabel)
	print("[LobbyCurrencyUI] 초기화 완료")
end

return LobbyCurrencyUI
