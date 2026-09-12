--[[
	서버 전용: Roblox 기본 플레이어 리스트(우측 상단)에 Level 컬럼 표시.
	기존 leaderstats 폴더가 있으면 Level IntValue만 추가한다.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LeaderstatsHandler = {}

local STAT_NAME = "Level"
local initialized = false

if not RunService:IsServer() then
	function LeaderstatsHandler.init() end

	function LeaderstatsHandler.setLevel(_player: Player, _level: number) end

	return LeaderstatsHandler
end

local function normalizeLevel(level: number): number
	if typeof(level) ~= "number" or level ~= level then
		return 1
	end
	return math.max(1, math.floor(level + 0.5))
end

local function ensureLevelStat(player: Player): IntValue?
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = player
	end

	local levelStat = leaderstats:FindFirstChild(STAT_NAME)
	if levelStat and not levelStat:IsA("IntValue") then
		levelStat:Destroy()
		levelStat = nil
	end

	if not levelStat then
		levelStat = Instance.new("IntValue")
		levelStat.Name = STAT_NAME
		levelStat.Value = 1
		levelStat.Parent = leaderstats
	end

	return levelStat :: IntValue
end

function LeaderstatsHandler.setLevel(player: Player, level: number)
	local levelStat = ensureLevelStat(player)
	if not levelStat then
		return
	end
	levelStat.Value = normalizeLevel(level)
end

local function onPlayerAdded(player: Player)
	LeaderstatsHandler.setLevel(player, 1)
end

function LeaderstatsHandler.init()
	if initialized then
		return
	end
	initialized = true

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return LeaderstatsHandler
