--[[
	로컬 플레이어 캐릭터 머리 위 경험치 바 (BillboardGui). 서버 Attribute XP / XPNext / XPLevel 사용.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CameraZoomModule = require(Shared.Utils.CameraZoomModule)
local ScaleModule = require(Shared.Utils.ScaleModule)
local LevelXpCurve = require(Shared.Config.LevelXpCurve)

local HeadXpBar = {}

local savedHumanoidHealthDisplay: { [Humanoid]: Enum.HumanoidHealthDisplayType } = {}

local function getXpCurveMaxLevel(): number
	local meta = LevelXpCurve.meta
	if typeof(meta) == "table" and typeof(meta.maxLevel) == "number" then
		return math.max(1, math.floor(meta.maxLevel))
	end
	return 1
end

-- 레벨 1: 아래 기준, 만렙에 가까울수록 배율 1→2
local STUDS_PAD_BASE = 0.85
local STUDS_FALLBACK_BASE = 1.95

local function xpLevelBoostMult(character: Model): number
	local maxL = getXpCurveMaxLevel()
	local lv = character:GetAttribute("XPLevel")
	local n = 1
	if typeof(lv) == "number" and lv == lv and lv >= 1 then
		n = math.floor(lv + 0.5)
	end
	local t = 1
	if maxL > 1 then
		t = math.clamp((n - 1) / (maxL - 1), 0, 1)
	end
	return 1 + t
end

-- 카메라 고정 줌 거리보다 MaxDistance가 짧으면(기본 120) 고레벨·대형 캐릭터에서 빌보드가 안 보임
local MAX_DISTANCE_MARGIN_STUDS = 180

local function findAttachPart(character: Model): BasePart?
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function ensureGui(character: Model): BillboardGui
	local existing = character:FindFirstChild("XpOverheadBillboard")
	if existing and existing:IsA("BillboardGui") then
		return existing
	end

	local bb = Instance.new("BillboardGui")
	bb.Name = "XpOverheadBillboard"
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(110, 52)
	bb.StudsOffset = Vector3.new(0, 1.35, 0)
	bb.MaxDistance = 400
	-- StudsOffset은 Adornee 로컬 공간; 아래 sync에서 실제 머리/리그 크기로 갱신
	bb.LightInfluence = 0
	bb.Parent = character

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = bb

	local levelLabel = Instance.new("TextLabel")
	levelLabel.Name = "LevelLabel"
	levelLabel.BackgroundTransparency = 1
	levelLabel.Size = UDim2.new(1, 0, 0, 18)
	levelLabel.Position = UDim2.fromScale(0, 0)
	levelLabel.Font = Enum.Font.GothamBold
	levelLabel.TextSize = 16
	levelLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	levelLabel.TextStrokeTransparency = 0.5
	levelLabel.Text = "Lv.1"
	levelLabel.Parent = root

	local barBack = Instance.new("Frame")
	barBack.Name = "BarBack"
	barBack.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
	barBack.BorderSizePixel = 0
	barBack.Size = UDim2.new(1, 0, 0, 10)
	barBack.Position = UDim2.new(0, 0, 0, 20)
	barBack.Parent = root

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = barBack

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = Color3.fromRGB(110, 200, 255)
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.Parent = barBack

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	local xpLabel = Instance.new("TextLabel")
	xpLabel.Name = "XpLabel"
	xpLabel.BackgroundTransparency = 1
	xpLabel.Size = UDim2.new(1, 0, 0, 16)
	xpLabel.Position = UDim2.new(0, 0, 1, -16)
	xpLabel.Font = Enum.Font.GothamBold
	xpLabel.TextSize = 13
	xpLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
	xpLabel.TextStrokeTransparency = 0.6
	xpLabel.Text = "0 / 100"
	xpLabel.Parent = root

	return bb
end

local function syncBillboardMaxDistance(bb: BillboardGui, character: Model)
	local scale = CameraZoomModule.getCharacterScale(character)
	local cameraOrbitStuds = CameraZoomModule.getFixedDistance(scale)
	bb.MaxDistance = cameraOrbitStuds + MAX_DISTANCE_MARGIN_STUDS
end

-- Model:ScaleTo(머리 크기) + XP 레벨 배율
local function syncBillboardStudsOffset(bb: BillboardGui, character: Model)
	local mult = xpLevelBoostMult(character)
	local pad = STUDS_PAD_BASE * mult
	local fb = STUDS_FALLBACK_BASE * mult

	local adornee = bb.Adornee
	if adornee and adornee:IsA("BasePart") then
		local halfY = adornee.Size.Y * 0.5
		bb.StudsOffset = Vector3.new(0, halfY + pad, 0)
		return
	end

	local s = ScaleModule.getCharacterScale(character)
	bb.StudsOffset = Vector3.new(0, fb * s, 0)
end

local function syncBillboardLayout(bb: BillboardGui, character: Model)
	syncBillboardMaxDistance(bb, character)
	syncBillboardStudsOffset(bb, character)
end

local function buildGui(character: Model): BillboardGui?
	local attach = findAttachPart(character)
	if not attach then
		return nil
	end

	local bb = ensureGui(character)
	bb.Adornee = attach
	syncBillboardLayout(bb, character)

	local function refresh()
		syncBillboardLayout(bb, character)
		local root = bb:FindFirstChild("Root")
		local levelLabel = root and root:FindFirstChild("LevelLabel")
		local barBack = root and root:FindFirstChild("BarBack")
		local fill = barBack and barBack:FindFirstChild("Fill")
		local xpLabel = root and root:FindFirstChild("XpLabel")
		if not (levelLabel and levelLabel:IsA("TextLabel")) then
			return
		end
		if not (xpLabel and xpLabel:IsA("TextLabel")) then
			return
		end
		if not (fill and fill:IsA("Frame")) then
			return
		end

		local xp = character:GetAttribute("XP")
		local xn = character:GetAttribute("XPNext")
		local lv = character:GetAttribute("XPLevel")
		if typeof(xp) ~= "number" then
			xp = 0
		end
		if typeof(xn) ~= "number" or xn <= 0 then
			xn = 100
		end
		if typeof(lv) ~= "number" then
			lv = 1
		end

		local maxLv = getXpCurveMaxLevel()
		local levelNum = math.floor(lv + 0.5)
		local atMaxLevel = levelNum >= maxLv

		if atMaxLevel then
			levelLabel.Text = string.format("Lv.%d (Max)", maxLv)
			barBack.Visible = false
			xpLabel.Visible = false
			bb.Size = UDim2.fromOffset(110, 22)
		else
			levelLabel.Text = "Lv." .. tostring(levelNum)
			barBack.Visible = true
			xpLabel.Visible = true
			bb.Size = UDim2.fromOffset(110, 52)
			xpLabel.Text = string.format("%d / %d", math.floor(xp + 0.5), math.floor(xn + 0.5))
			local ratio = math.clamp(xp / xn, 0, 1)
			fill.Size = UDim2.fromScale(ratio, 1)
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			if savedHumanoidHealthDisplay[humanoid] == nil then
				savedHumanoidHealthDisplay[humanoid] = humanoid.HealthDisplayType
			end
			if atMaxLevel then
				humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
			else
				humanoid.HealthDisplayType = savedHumanoidHealthDisplay[humanoid]
			end
		end
	end

	refresh()
	if not bb:GetAttribute("SignalsBound") then
		character:GetAttributeChangedSignal("XP"):Connect(refresh)
		character:GetAttributeChangedSignal("XPNext"):Connect(refresh)
		character:GetAttributeChangedSignal("XPLevel"):Connect(refresh)
		bb:SetAttribute("SignalsBound", true)
	end

	-- 레벨업 후 ScaleTo가 속성 갱신보다 늦을 때 카메라 거리에 맞춰 MaxDistance 재보정
	if not bb:GetAttribute("MaxDistanceSyncBound") then
		bb:SetAttribute("MaxDistanceSyncBound", true)
		local lastScale = CameraZoomModule.getCharacterScale(character)
		local conn: RBXScriptConnection?
		conn = RunService.Heartbeat:Connect(function()
			if not (bb.Parent and character.Parent) then
				if conn then
					conn:Disconnect()
				end
				return
			end
			local s = CameraZoomModule.getCharacterScale(character)
			if math.abs(s - lastScale) > 0.02 then
				lastScale = s
				syncBillboardLayout(bb, character)
			end
		end)
	end

	return bb
end

local function onCharacter(character: Model)
	local function tryBuild()
		if not character.Parent then
			return
		end
		buildGui(character)
	end

	task.defer(tryBuild)

	character.DescendantAdded:Connect(function(inst)
		if inst.Name == "Head" or inst.Name == "HumanoidRootPart" then
			tryBuild()
		end
	end)

	character:GetPropertyChangedSignal("Parent"):Connect(function()
		if character.Parent then
			tryBuild()
		end
	end)
end

function HeadXpBar.init()
	local player = Players.LocalPlayer
	if not player then
		return
	end

	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		onCharacter(player.Character)
	end
end

return HeadXpBar
