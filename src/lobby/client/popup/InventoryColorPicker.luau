--[[
	InventoryColorPicker (lobby client)

	Viperdune Circular Color Picker 로직 포팅.
	GUI 트리: InventoryPopup.Custom.ColorWindow
		https://devforum.roblox.com/t/2577233
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")

local InventoryColorPicker = {}

local function toPolar(v: Vector2): (number, number)
	return math.atan2(v.Y, v.X), v.Magnitude
end

local function radToDeg(x: number): number
	return ((x + math.pi) / (2 * math.pi)) * 360
end

local function roundToHundredths(num: number): number
	return math.round(num * 100) / 100
end

export type Options = {
	initialColor: Color3?,
	onUpdated: ((color: Color3) -> ())?,
	onFinished: ((color: Color3) -> ())?,
	onCanceled: (() -> ())?,
	draggable: boolean?,
}

export type Session = {
	setColor: (color: Color3) -> (),
	getColor: () -> Color3,
	destroy: () -> (),
}

function InventoryColorPicker.bind(colorWindow: Frame, options: Options?): Session
	local opts = options or {}
	local connections: { RBXScriptConnection } = {}
	local dragConn: RBXScriptConnection? = nil
	local wheelConn: RBXScriptConnection? = nil
	local valueConn: RBXScriptConnection? = nil

	local hue = 0
	local saturation = 0
	local value = 1

	local updateEvent = colorWindow:FindFirstChild("UpdateEvent") :: BindableEvent?
	local finishedEvent = colorWindow:FindFirstChild("FinishedEvent") :: BindableEvent?
	local canceledEvent = colorWindow:FindFirstChild("CanceledEvent") :: BindableEvent?

	local content = colorWindow:FindFirstChild("Content")
	local properties = colorWindow:FindFirstChild("Properties")

	local function getMousePos(): Vector2?
		local mousePos = UserInputService:GetMouseLocation()
		return mousePos - Vector2.new(0, GuiService.TopbarInset.Height)
	end

	local function updateColorVisual()
		local color = Color3.fromHSV(hue, saturation, value)

		if updateEvent then
			updateEvent:Fire(color)
		end
		if opts.onUpdated then
			opts.onUpdated(color)
		end

		if not content then
			return
		end

		local right = content:FindFirstChild("Right")
		local valueSlider = right and right:FindFirstChild("Value")
		local gradient = valueSlider and valueSlider:FindFirstChild("UIGradient") :: UIGradient?
		if gradient then
			gradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromHSV(hue, saturation, 1)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 0)),
			})
		end

		local bottom = content:FindFirstChild("Bottom")
		local colorPreview = bottom and bottom:FindFirstChild("Color")
		local previewFrame = colorPreview and colorPreview:FindFirstChild("Frame")
		if previewFrame and previewFrame:IsA("GuiObject") then
			previewFrame.BackgroundColor3 = color
		end

		local hexRow = bottom and bottom:FindFirstChild("Hex")
		local hexFrame = hexRow and hexRow:FindFirstChild("Frame")
		local hexText = hexFrame and hexFrame:FindFirstChild("TextBox") :: TextBox?
		if hexText then
			hexText.Text = string.format("#%s", color:ToHex())
		end
		local invalidStroke = hexFrame and hexFrame:FindFirstChild("InvalidStroke") :: UIStroke?
		if invalidStroke then
			invalidStroke.Enabled = false
		end

		if not properties then
			return
		end

		local rgb = properties:FindFirstChild("RGB")
		if rgb then
			local function setChannel(channelName: string, channelValue: number)
				local channel = rgb:FindFirstChild(channelName)
				local frame = channel and channel:FindFirstChild("Frame")
				local textBox = frame and frame:FindFirstChild("TextBox") :: TextBox?
				if textBox then
					textBox.Text = tostring(channelValue)
				end
			end
			setChannel("R", math.floor(color.R * 255))
			setChannel("G", math.floor(color.G * 255))
			setChannel("B", math.floor(color.B * 255))
		end

		local hsv = properties:FindFirstChild("HSV")
		if hsv then
			local function setChannel(channelName: string, channelValue: string)
				local channel = hsv:FindFirstChild(channelName)
				local frame = channel and channel:FindFirstChild("Frame")
				local textBox = frame and frame:FindFirstChild("TextBox") :: TextBox?
				if textBox then
					textBox.Text = channelValue
				end
			end
			setChannel("H", tostring(math.floor(hue * 360)))
			setChannel("S", tostring(roundToHundredths(saturation)))
			setChannel("V", tostring(roundToHundredths(value)))
		end
	end

	local function setColor(c: Color3)
		local h, s, v = c:ToHSV()
		hue = h
		saturation = s
		value = v

		if content then
			local wheel = content:FindFirstChild("Wheel")
			local wheelImage = wheel and wheel:FindFirstChild("Image")
			local select = wheelImage and wheelImage:FindFirstChild("Select")
			if select then
				local h2 = h * math.pi * 2
				local wv = Vector2.new(-math.cos(h2) / 2 * s, math.sin(h2) / 2 * s)
				select.Position = UDim2.fromScale(0.5 + wv.X, 0.5 + wv.Y)
			end

			local right = content:FindFirstChild("Right")
			local valueSlider = right and right:FindFirstChild("Value")
			local valueSelect = valueSlider and valueSlider:FindFirstChild("Select")
			if valueSelect then
				valueSelect.Position = UDim2.fromScale(0, 1 - v)
			end
		end

		updateColorVisual()
	end

	local function stopDragInteractions()
		local overlay = colorWindow:FindFirstChild("Button") :: GuiObject?
		if overlay then
			overlay.Visible = false
		end
		if wheelConn then
			wheelConn:Disconnect()
			wheelConn = nil
		end
		if valueConn then
			valueConn:Disconnect()
			valueConn = nil
		end
		if dragConn then
			dragConn:Disconnect()
			dragConn = nil
		end
	end

	if opts.draggable ~= false then
		local topbar = colorWindow:FindFirstChild("Topbar")
		local topbarButton = topbar and topbar:FindFirstChild("Button")
		if topbarButton and topbarButton:IsA("GuiButton") then
			table.insert(connections, topbarButton.MouseButton1Down:Connect(function()
				local startMousePos = getMousePos() or Vector2.zero
				local startWindowPos = colorWindow.Position
				dragConn = RunService.Heartbeat:Connect(function()
					local pos = (getMousePos() or Vector2.zero) - startMousePos
					colorWindow.Position = startWindowPos + UDim2.fromOffset(pos.X, pos.Y)
				end)
			end))
		end
	end

	local wheel = content and content:FindFirstChild("Wheel")
	local wheelButton = wheel and wheel:FindFirstChild("Button")
	if wheelButton then
		table.insert(connections, wheelButton.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			local overlay = colorWindow:FindFirstChild("Button") :: GuiObject?
			if overlay then
				overlay.Visible = true
			end
			wheelConn = RunService.Heartbeat:Connect(function()
				local mousePos = getMousePos()
				local wheelImage = wheel and wheel:FindFirstChild("Image")
				local select = wheelImage and wheelImage:FindFirstChild("Select")
				if not (mousePos and wheelImage and select) then
					return
				end

				local wheelMid = wheelImage.AbsolutePosition + wheelImage.AbsoluteSize / 2
				local toWheelMid = (mousePos - wheelMid) / wheelImage.AbsoluteSize
				if toWheelMid.Magnitude > 0.5 then
					toWheelMid = toWheelMid.Unit / 2
				end

				select.Position = UDim2.fromScale(0.5 + toWheelMid.X, 0.5 + toWheelMid.Y)

				local phi, len = toPolar(toWheelMid * Vector2.new(1, -1))
				hue = math.clamp(radToDeg(phi) / 360, 0, 1)
				saturation = math.clamp(len * 2, 0, 1)
				updateColorVisual()
			end)
		end))
	end

	local valueSlider = content and content:FindFirstChild("Right") and content.Right:FindFirstChild("Value")
	local valueButton = valueSlider and valueSlider:FindFirstChild("Button")
	if valueButton then
		table.insert(connections, valueButton.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			local overlay = colorWindow:FindFirstChild("Button") :: GuiObject?
			if overlay then
				overlay.Visible = true
			end
			valueConn = RunService.Heartbeat:Connect(function()
				local mousePos = getMousePos()
				local select = valueSlider and valueSlider:FindFirstChild("Select")
				if not (mousePos and valueSlider and select) then
					return
				end

				local valueTop = valueSlider.AbsolutePosition
				value = 1 - math.clamp((mousePos.Y - valueTop.Y) / valueSlider.AbsoluteSize.Y, 0, 1)
				select.Position = UDim2.fromScale(0, 1 - value)
				updateColorVisual()
			end)
		end))
	end

	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			stopDragInteractions()
		end
	end))

	local bottom = content and content:FindFirstChild("Bottom")
	local hexRow = bottom and bottom:FindFirstChild("Hex")
	local hexFrame = hexRow and hexRow:FindFirstChild("Frame")
	local hexText = hexFrame and hexFrame:FindFirstChild("TextBox") :: TextBox?
	if hexText then
		table.insert(connections, hexText.FocusLost:Connect(function()
			local hexTextValue = hexText.Text
			local ok, color = pcall(function()
				return Color3.fromHex(hexTextValue)
			end)
			local invalidStroke = hexFrame:FindFirstChild("InvalidStroke") :: UIStroke?
			if invalidStroke then
				invalidStroke.Enabled = not ok
			end
			if not ok then
				warn(string.format("[InventoryColorPicker] %s is not a valid hex color.", hexTextValue))
				return
			end
			setColor(color)
		end))
	end

	if properties then
		local rgb = properties:FindFirstChild("RGB")
		if rgb then
			for _, channel in rgb:GetChildren() do
				if channel:IsA("Frame") then
					local frame = channel:FindFirstChild("Frame")
					local textBox = frame and frame:FindFirstChild("TextBox") :: TextBox?
					if textBox then
						table.insert(connections, textBox.FocusLost:Connect(function()
							local rChannel = rgb:FindFirstChild("R")
							local gChannel = rgb:FindFirstChild("G")
							local bChannel = rgb:FindFirstChild("B")
							local rBox = rChannel and rChannel:FindFirstChild("Frame") and rChannel.Frame:FindFirstChild("TextBox") :: TextBox?
							local gBox = gChannel and gChannel:FindFirstChild("Frame") and gChannel.Frame:FindFirstChild("TextBox") :: TextBox?
							local bBox = bChannel and bChannel:FindFirstChild("Frame") and bChannel.Frame:FindFirstChild("TextBox") :: TextBox?
							if not (rBox and gBox and bBox) then
								return
							end
							setColor(Color3.fromRGB(
								math.clamp(tonumber(rBox.Text) or 255, 0, 255),
								math.clamp(tonumber(gBox.Text) or 255, 0, 255),
								math.clamp(tonumber(bBox.Text) or 255, 0, 255)
							))
						end))
					end
				end
			end
		end

		local hsv = properties:FindFirstChild("HSV")
		if hsv then
			for _, channel in hsv:GetChildren() do
				if channel:IsA("Frame") then
					local frame = channel:FindFirstChild("Frame")
					local textBox = frame and frame:FindFirstChild("TextBox") :: TextBox?
					if textBox then
						table.insert(connections, textBox.FocusLost:Connect(function()
							local hChannel = hsv:FindFirstChild("H")
							local sChannel = hsv:FindFirstChild("S")
							local vChannel = hsv:FindFirstChild("V")
							local hBox = hChannel and hChannel:FindFirstChild("Frame") and hChannel.Frame:FindFirstChild("TextBox") :: TextBox?
							local sBox = sChannel and sChannel:FindFirstChild("Frame") and sChannel.Frame:FindFirstChild("TextBox") :: TextBox?
							local vBox = vChannel and vChannel:FindFirstChild("Frame") and vChannel.Frame:FindFirstChild("TextBox") :: TextBox?
							if not (hBox and sBox and vBox) then
								return
							end
							setColor(Color3.fromHSV(
								math.clamp(tonumber(hBox.Text) or 0, 0, 360) / 360,
								math.clamp(tonumber(sBox.Text) or 1, 0, 1),
								math.clamp(tonumber(vBox.Text) or 1, 0, 1)
							))
						end))
					end
				end
			end
		end
	end

	local buttons = bottom and bottom:FindFirstChild("Buttons")
	local confirm = buttons and buttons:FindFirstChild("Confirm")
	local cancel = buttons and buttons:FindFirstChild("Cancel")

	if confirm then
		table.insert(connections, confirm.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			local color = Color3.fromHSV(hue, saturation, value)
			if finishedEvent then
				finishedEvent:Fire(color)
			end
			if opts.onFinished then
				opts.onFinished(color)
			end
		end))
	end

	if cancel then
		table.insert(connections, cancel.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			if canceledEvent then
				canceledEvent:Fire()
			end
			if opts.onCanceled then
				opts.onCanceled()
			end
		end))
	end

	setColor(opts.initialColor or Color3.fromRGB(255, 255, 255))

	return {
		setColor = setColor,
		getColor = function()
			return Color3.fromHSV(hue, saturation, value)
		end,
		destroy = function()
			stopDragInteractions()
			for _, conn in connections do
				conn:Disconnect()
			end
			table.clear(connections)
		end,
	}
end

return InventoryColorPicker
