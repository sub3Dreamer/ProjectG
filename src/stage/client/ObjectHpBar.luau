--[[
	Damageable object HP bar (fill only, no numeric text).
	최대 MAX_BARS개 UI만 풀링; 공격으로 activate된 Prop만 표시(LRU 재활용).
]]

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameSettings = require(Shared.Config.GameSettings)
local AttackDamageCurve = require(Shared.Config.AttackDamageCurve)
local ScaleModule = require(Shared.Utils.ScaleModule)
local ModelWorldExtents = require(Shared.Utils.ModelWorldExtents)

local ObjectHpBar = {}

local player = Players.LocalPlayer

local hpAttrName = GameSettings.Combat.CurrentHitPointAttributeName or "CurrentHitPoint"
local tierAttrName = GameSettings.Combat.TierAttributeName or "Tier"

local MAX_BARS = 5

type BarSlot = {
	root: Frame,
	fill: Frame,
	owner: Instance?,
	activatedAt: number,
}

local maxHpCache: { [Instance]: number } = {}
local pool: { BarSlot } = {}
local ownerToSlot: { [Instance]: number } = {}
local screenGuiRef: ScreenGui? = nil

local BAR_MIN_STUDS = 2.1
local BAR_HEIGHT_FRAC = 0.11
local BAR_PER_LEVEL = 0.85
local BAR_SIZE = Vector2.new(84, 14)
local VIEWPORT_INSET_PX = 20

local function parseTier(v: any): number?
	if typeof(v) == "number" and v == v and v >= 1 then
		return math.floor(v + 0.5)
	end
	if typeof(v) == "string" then
		local n = tonumber(v)
		if n and n >= 1 then
			return math.floor(n + 0.5)
		end
	end
	return nil
end

local function tierOnModel(model: Model): number?
	local parsed = parseTier(model:GetAttribute(tierAttrName))
	if parsed then
		return parsed
	end
	local child = model:FindFirstChild(tierAttrName)
	if child and child:IsA("NumberValue") then
		return parseTier((child :: NumberValue).Value)
	end
	if child and child:IsA("IntValue") then
		return parseTier((child :: IntValue).Value)
	end
	if child and child:IsA("StringValue") then
		return parseTier((child :: StringValue).Value)
	end
	return nil
end

local function getLocalPlayerLevel(): number
	local character = player.Character
	if not character then
		return 1
	end
	local level = character:GetAttribute("XPLevel")
	if typeof(level) == "number" and level == level and level >= 1 then
		return math.floor(level + 0.5)
	end
	return 1
end

local function shouldHideHpBarDueToLevelGap(owner: Instance): boolean
	if not owner:IsA("Model") then
		return false
	end
	local objTier = tierOnModel(owner)
	if not objTier then
		return false
	end
	local gap = GameSettings.Combat.AutoDestroyLevelGap or 3
	return getLocalPlayerLevel() - objTier >= gap
end

local function getAttackCurveMaxLevel(): number
	local m = AttackDamageCurve.meta
	if typeof(m) == "table" and typeof(m.maxLevel) == "number" then
		return math.max(1, math.floor(m.maxLevel))
	end
	return 9
end

local function barTierBoostMult(tier: number?): number
	if not tier then
		return 1
	end
	local maxL = getAttackCurveMaxLevel()
	local t = 1
	if maxL > 1 then
		t = math.clamp((tier - 1) / (maxL - 1), 0, 1)
	end
	return 1 + t
end

local function objectTierForOwner(owner: Instance): number?
	if owner:IsA("Model") then
		return tierOnModel(owner)
	end
	local m = owner:FindFirstAncestorOfClass("Model")
	if m then
		return tierOnModel(m)
	end
	return nil
end

local function getOwnerWorldScale(owner: Instance): number
	local model: Instance? = owner
	if owner:IsA("BasePart") then
		model = owner:FindFirstAncestorOfClass("Model")
	end
	if model and model:IsA("Model") then
		local ok, s = pcall(function()
			return (model :: Model):GetScale()
		end)
		if ok and typeof(s) == "number" and s == s and s > 0 then
			return s
		end
	end
	return 1
end

local function barMarginAboveWorldTop(owner: Instance, verticalExtentStuds: number): number
	local scale = getOwnerWorldScale(owner)
	local oTier = objectTierForOwner(owner)
	local mult = barTierBoostMult(oTier)

	local minStuds = BAR_MIN_STUDS * mult
	local heightFrac = BAR_HEIGHT_FRAC * mult
	local perLevel = BAR_PER_LEVEL * mult

	local fromHeight = verticalExtentStuds * heightFrac
	local fromMin = minStuds * scale
	local margin = math.max(fromMin, fromHeight)

	if oTier and oTier > 1 then
		margin += (oTier - 1) * perLevel * scale
	end

	return margin
end

local function getScreenGui(): ScreenGui
	local pg = player:WaitForChild("PlayerGui")
	local existing = pg:FindFirstChild("ObjectHpBarsOverlay")
	if existing and existing:IsA("ScreenGui") then
		return existing
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "ObjectHpBarsOverlay"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 50
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = pg
	return sg
end

local function getAttachPart(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	end
	if inst:IsA("Model") then
		local primary = inst.PrimaryPart
		if primary then
			return primary
		end
		local firstPart = inst:FindFirstChildWhichIsA("BasePart", true)
		if firstPart then
			return firstPart
		end
	end
	return nil
end

local function getCurrentScale(): number
	local character = player and player.Character
	if not character then
		return 1
	end

	return ScaleModule.getCharacterScale(character)
end

local function isOwnerInAttackRange(owner: Instance): boolean
	local character = player and player.Character
	if not character then
		return false
	end

	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoidRootPart or not humanoidRootPart:IsA("BasePart") then
		return false
	end

	local scale = getCurrentScale()
	local range = GameSettings.Combat.AttackRange * scale
	local boxScale = GameSettings.Combat.AttackBoxScale or Vector3.new(1, 1, 1)
	local offset = GameSettings.Combat.AttackOffset
	local lookVector = humanoidRootPart.CFrame.LookVector
	local boxCenter = humanoidRootPart.CFrame * CFrame.new(offset) + lookVector * (range / 2)
	local halfSize = (Vector3.new(range, range, range) * boxScale) * 0.5
	local radius = (boxCenter.Position - humanoidRootPart.Position).Magnitude + halfSize.Magnitude + 0.5

	local overlapParams = OverlapParams.new()
	overlapParams.FilterDescendantsInstances = { character }
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude

	for _, part in Workspace:GetPartBoundsInRadius(humanoidRootPart.Position, radius, overlapParams) do
		if part:IsDescendantOf(owner) then
			return true
		end
	end

	return false
end

local function maxWorldYFromObb(cf: CFrame, size: Vector3): number
	local hs = size * 0.5
	local pos = cf.Position
	local r = cf.RightVector
	local u = cf.UpVector
	local l = cf.LookVector
	local maxY = -math.huge
	local signs = { -1, 1 }
	for _, sx in ipairs(signs) do
		for _, sy in ipairs(signs) do
			for _, sz in ipairs(signs) do
				local corner = pos + r * (hs.X * sx) + u * (hs.Y * sy) + l * (hs.Z * sz)
				if corner.Y > maxY then
					maxY = corner.Y
				end
			end
		end
	end
	return maxY
end

local function getWorldBarPosition(owner: Instance): Vector3?
	if owner:IsA("Model") then
		-- 공격판정용 투명 파츠(예: 세로로 큰 히트박스)를 제외한 실제 렌더링 영역 기준으로 배치.
		local visible = ModelWorldExtents.computeVisible(owner :: Model)
		if visible and visible.sizeY > 0 then
			local margin = barMarginAboveWorldTop(owner, visible.sizeY)
			return Vector3.new(visible.centerX, visible.topY + margin, visible.centerZ)
		end

		-- 보이는 파츠가 없으면(전부 투명 등) 기존 OBB 기반 방식으로 폴백.
		local ok, cf, size = pcall(function()
			return (owner :: Model):GetBoundingBox()
		end)
		if ok and cf and size then
			local topY = maxWorldYFromObb(cf, size)
			if topY > -math.huge then
				local p = cf.Position
				local margin = barMarginAboveWorldTop(owner, size.Y)
				return Vector3.new(p.X, topY + margin, p.Z)
			end
		end
	end

	local attach = getAttachPart(owner)
	if not attach then
		return nil
	end
	local attachLift = barMarginAboveWorldTop(owner, attach.Size.Y)
	return (attach.CFrame * CFrame.new(0, attachLift, 0)).Position
end

local function applyScreenPositionClamped(root: Frame, worldPos: Vector3)
	local cam = Workspace.CurrentCamera
	if not cam then
		root.Visible = false
		return
	end

	local vp = cam:WorldToViewportPoint(worldPos)
	if vp.Z <= 0 then
		root.Visible = false
		return
	end

	local size = cam.ViewportSize
	local halfW = BAR_SIZE.X * 0.5
	local halfH = BAR_SIZE.Y * 0.5
	local inset = VIEWPORT_INSET_PX

	local minX = inset + halfW
	local maxX = size.X - inset - halfW
	local minY = inset + halfH
	local maxY = size.Y - inset - halfH

	if maxX < minX or maxY < minY then
		root.Visible = false
		return
	end

	local x = math.clamp(vp.X, minX, maxX)
	local y = math.clamp(vp.Y, minY, maxY)
	root.Visible = true
	root.Position = UDim2.fromOffset(x, y)
end

local function createBarSlotUi(gui: ScreenGui, slotIndex: number): BarSlot
	local root = Instance.new("Frame")
	root.Name = "ObjectHpBar_" .. slotIndex
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Size = UDim2.fromOffset(BAR_SIZE.X, BAR_SIZE.Y)
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Visible = false
	root.Parent = gui

	local back = Instance.new("Frame")
	back.Name = "BarBack"
	back.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	back.BorderSizePixel = 0
	back.Size = UDim2.new(1, 0, 0, 11)
	back.Position = UDim2.new(0, 0, 0.5, -5.5)
	back.Parent = root

	local backCorner = Instance.new("UICorner")
	backCorner.CornerRadius = UDim.new(0, 4)
	backCorner.Parent = back

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = Color3.fromRGB(80, 200, 120)
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(1, 1)
	fill.Parent = back

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	return {
		root = root,
		fill = fill,
		owner = nil,
		activatedAt = 0,
	}
end

local function initBarPool()
	table.clear(pool)
	table.clear(ownerToSlot)

	local gui = screenGuiRef
	if not gui or not gui.Parent then
		gui = getScreenGui()
		screenGuiRef = gui
	end

	for i = 1, MAX_BARS do
		pool[i] = createBarSlotUi(gui, i)
	end
end

local function releaseSlot(slotIndex: number)
	local slot = pool[slotIndex]
	if not slot then
		return
	end
	local prevOwner = slot.owner
	if prevOwner then
		ownerToSlot[prevOwner] = nil
		maxHpCache[prevOwner] = nil
	end
	slot.owner = nil
	slot.activatedAt = 0
	slot.root.Visible = false
end

local function findOldestSlotIndex(): number
	local oldest = 1
	for i = 2, MAX_BARS do
		if pool[i].activatedAt < pool[oldest].activatedAt then
			oldest = i
		end
	end
	return oldest
end

function ObjectHpBar.activate(owner: Instance)
	if not owner:IsA("Model") then
		return
	end
	if not owner.Parent then
		return
	end

	local hp = owner:GetAttribute(hpAttrName)
	if typeof(hp) ~= "number" or hp ~= hp or hp <= 0 then
		return
	end

	local existingSlot = ownerToSlot[owner]
	if existingSlot then
		pool[existingSlot].activatedAt = tick()
		return
	end

	local slotIndex: number? = nil
	for i, slot in ipairs(pool) do
		if slot.owner == nil then
			slotIndex = i
			break
		end
	end

	if not slotIndex then
		local evictIndex = findOldestSlotIndex()
		releaseSlot(evictIndex)
		slotIndex = evictIndex
	end

	local assignedIndex = slotIndex :: number
	local slot = pool[assignedIndex]
	slot.owner = owner
	slot.activatedAt = tick()
	ownerToSlot[owner] = assignedIndex
end

local function updateSlot(slot: BarSlot)
	local owner = slot.owner
	if not owner or not owner.Parent then
		return
	end

	local hp = owner:GetAttribute(hpAttrName)
	if typeof(hp) ~= "number" or hp < 0 then
		return
	end

	if hp <= 0 then
		local slotIndex = ownerToSlot[owner]
		if slotIndex then
			releaseSlot(slotIndex)
		end
		return
	end

	local maxHp = owner:GetAttribute("MaxHitPoint")
	if typeof(maxHp) ~= "number" or maxHp <= 0 then
		maxHp = maxHpCache[owner] or hp
	end
	maxHp = math.max(1, math.floor(maxHp + 0.5))
	maxHpCache[owner] = math.max(maxHpCache[owner] or 0, maxHp, math.floor(hp + 0.5))

	if shouldHideHpBarDueToLevelGap(owner) then
		slot.root.Visible = false
		return
	end

	if not isOwnerInAttackRange(owner) then
		slot.root.Visible = false
		return
	end

	local worldPos = getWorldBarPosition(owner)
	if not worldPos then
		slot.root.Visible = false
		return
	end

	applyScreenPositionClamped(slot.root, worldPos)

	local clampedHp = math.max(0, math.floor(hp + 0.5))
	local ratio = math.clamp(clampedHp / maxHpCache[owner], 0, 1)
	slot.fill.Size = UDim2.fromScale(ratio, 1)

	if ratio <= 0.25 then
		slot.fill.BackgroundColor3 = Color3.fromRGB(220, 70, 70)
	elseif ratio <= 0.6 then
		slot.fill.BackgroundColor3 = Color3.fromRGB(230, 180, 70)
	else
		slot.fill.BackgroundColor3 = Color3.fromRGB(80, 200, 120)
	end
end

function ObjectHpBar.init()
	screenGuiRef = getScreenGui()
	initBarPool()

	RunService.Heartbeat:Connect(function()
		for i, slot in ipairs(pool) do
			if slot.owner then
				if slot.owner.Parent then
					updateSlot(slot)
				else
					releaseSlot(i)
				end
			end
		end
	end)
end

return ObjectHpBar
