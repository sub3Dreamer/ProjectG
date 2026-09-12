local EnemyOverheadHpBar = {}

local FILL_RED = Color3.fromRGB(230, 35, 45)
local BG_COLOR = Color3.fromRGB(25, 25, 25)

function EnemyOverheadHpBar.attach(model: Model)
	local head = model:FindFirstChild("Head")
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not head or not head:IsA("BasePart") or not humanoid then
		return
	end

	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	local bb = Instance.new("BillboardGui")
	bb.Name = "EnemyHpBillboard"
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(104, 14)
	bb.StudsOffset = Vector3.new(0, 0.95, 0)
	bb.MaxDistance = 200
	bb.LightInfluence = 0
	bb.Parent = head

	local bg = Instance.new("Frame")
	bg.Name = "BarBackground"
	bg.BackgroundColor3 = BG_COLOR
	bg.BackgroundTransparency = 0.25
	bg.BorderSizePixel = 0
	bg.Size = UDim2.fromScale(1, 1)
	bg.Parent = bb

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(0, 5)
	bgCorner.Parent = bg

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 2)
	padding.PaddingRight = UDim.new(0, 2)
	padding.PaddingTop = UDim.new(0, 2)
	padding.PaddingBottom = UDim.new(0, 2)
	padding.Parent = bg

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = FILL_RED
	fill.BorderSizePixel = 0
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.Parent = bg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 3)
	fillCorner.Parent = fill

	local function updateFill()
		local maxH = math.max(0.001, humanoid.MaxHealth)
		local t = math.clamp(humanoid.Health / maxH, 0, 1)
		fill.Size = UDim2.new(t, 0, 1, 0)
	end

	updateFill()
	humanoid.HealthChanged:Connect(updateFill)
	humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(updateFill)
end

return EnemyOverheadHpBar
