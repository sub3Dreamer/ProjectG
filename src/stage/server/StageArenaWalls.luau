--[[
	스테이지 플레이 시작 시 Workspace 에 투명 사각 벽 4면 생성 (서버, 전원 공통).
	경계는 GameSettings.ArenaWalls (2048×2048 → HalfExtents 1024).
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameSettings = require(Shared.Config.GameSettings)

local FOLDER_NAME = "StageArenaWalls"

local created = false

local function buildWall(name: string, cf: CFrame, size: Vector3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = true
	p.CanQuery = true
	p.CastShadow = false
	p.Transparency = 1
	p.Material = Enum.Material.SmoothPlastic
	p.Color = Color3.fromRGB(1, 1, 1)
	p.CFrame = cf
	p.Size = size
	return p
end

local StageArenaWalls = {}

--- 클라이언트가 게임 시작 연출 완료 시 호출. 세션당 1회만 생성.
function StageArenaWalls.ensureOnce()
	if created then
		return
	end
	created = true

	local cfg = GameSettings.ArenaWalls
	if typeof(cfg) ~= "table" then
		warn("[StageArenaWalls] GameSettings.ArenaWalls 없음")
		return
	end

	local center = cfg.Center :: Vector3
	local hx = tonumber(cfg.HalfExtentsX) or 1024
	local hz = tonumber(cfg.HalfExtentsZ) or 1024
	local t = tonumber(cfg.Thickness) or 20
	local ch = tonumber(cfg.CharacterHeightAtScale1Studs) or 14
	local extra = tonumber(cfg.ExtraHeightStuds) or 200
	local maxScale = (GameSettings.Scale and tonumber(GameSettings.Scale.MaxScale)) or 52.2

	local wallHeight = maxScale * ch + extra
	if wallHeight < 80 then
		wallHeight = 80
	end

	local floorY = center.Y
	local yMid = floorY + wallHeight * 0.5

	local old = Workspace:FindFirstChild(FOLDER_NAME)
	if old then
		old:Destroy()
	end

	local folder = Instance.new("Model")
	folder.Name = FOLDER_NAME

	local lenX = hx * 2 + t * 2
	local lenZ = hz * 2 + t * 2

	local east = buildWall(
		"Wall_PosX",
		CFrame.new(center.X + hx + t * 0.5, yMid, center.Z),
		Vector3.new(t, wallHeight, lenZ)
	)
	local west = buildWall(
		"Wall_NegX",
		CFrame.new(center.X - hx - t * 0.5, yMid, center.Z),
		Vector3.new(t, wallHeight, lenZ)
	)
	local north = buildWall(
		"Wall_PosZ",
		CFrame.new(center.X, yMid, center.Z + hz + t * 0.5),
		Vector3.new(lenX, wallHeight, t)
	)
	local south = buildWall(
		"Wall_NegZ",
		CFrame.new(center.X, yMid, center.Z - hz - t * 0.5),
		Vector3.new(lenX, wallHeight, t)
	)

	east.Parent = folder
	west.Parent = folder
	north.Parent = folder
	south.Parent = folder
	folder.Parent = Workspace

	print(
		string.format(
			"[StageArenaWalls] 생성 완료 H=%.0f hx=%.0f hz=%.0f t=%.0f floorY=%.1f",
			wallHeight,
			hx,
			hz,
			t,
			floorY
		)
	)
end

return StageArenaWalls
