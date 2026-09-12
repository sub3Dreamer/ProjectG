--[[
	PetMarkerArea(지면 마커) prefab의 AreaRadius/AreaHeight 속성에 맞춰 InnerCylinder/
	GradientCylinder/NeonRing/PointLight을 스케일링한다.

	ServerStorage.PetMarkerArea 자체는 Rojo로 동기화되지 않는 Studio 전용 프리팹(UFO/
	SpeechBubbleTemplate과 동일 패턴)이라, 그 안에 별도 Script를 심는 대신 이 ModuleScript를
	SpeechBubbleManager가 직접 require해서 Clone 직후 attach()를 호출하는 방식으로 연동한다.
]]

local PetMarkerAreaVisualSync = {}

local BASE_RADIUS = 6 -- 기준 반지름 (InnerCylinder Size.X / 2)
local BASE_HEIGHT = 2.6 -- GradientCylinder 기본 높이

type RingPartData = {
	part: BasePart,
	offsetX: number,
	offsetZ: number,
	originalY: number,
	originalZ: number,
	originalX: number,
	originalYSize: number,
}

--- petMarkerArea(PetMarkerArea 템플릿의 Clone 1개)를 1회 초기화해, 이후 AreaRadius/AreaHeight
--- 속성 변화에 반응해 시각 요소를 다시 스케일링하도록 연결한다. attach 시점의 현재 속성값(없으면
--- BASE_RADIUS/BASE_HEIGHT)을 즉시 1회 반영한다.
---
--- 반환하는 함수를 호출하면 연결을 끊는다 — petMarkerArea:Destroy()를 호출하면 Roblox가 이
--- 인스턴스에 걸린 연결을 자동으로 정리하므로, 별도 수명 관리가 필요 없는 일반적인 호출부는
--- 반환값을 무시해도 된다.
function PetMarkerAreaVisualSync.attach(petMarkerArea: Model): () -> ()
	local lightCore = petMarkerArea:WaitForChild("LightCore") :: BasePart
	local innerCylinder = petMarkerArea:WaitForChild("InnerCylinder") :: BasePart
	local gradientCylinder = petMarkerArea:WaitForChild("GradientCylinder") :: BasePart
	local neonRing = petMarkerArea:WaitForChild("NeonRing") :: Instance
	local pointLight = lightCore:WaitForChild("PointLight") :: PointLight

	local originalInnerY = innerCylinder.Size.Y
	local originalGradientPivot = gradientCylinder:GetPivot()

	local ringParts: { RingPartData } = {}
	for _, part in neonRing:GetChildren() do
		if part:IsA("BasePart") then
			local offset = part.Position - lightCore.Position
			table.insert(ringParts, {
				part = part,
				offsetX = offset.X,
				offsetZ = offset.Z,
				originalY = part.Position.Y,
				originalZ = part.Size.Z,
				originalX = part.Size.X,
				originalYSize = part.Size.Y,
			})
		end
	end

	local function applyRadius(radius: number)
		if typeof(radius) ~= "number" or radius <= 0 then
			return
		end

		local scale = radius / BASE_RADIUS
		local diameter = radius * 2

		-- InnerCylinder: X, Z를 반지름에 맞춰 스케일
		innerCylinder.Size = Vector3.new(diameter, originalInnerY, diameter)

		-- GradientCylinder: X, Z는 반지름에 맞춰 스케일, Y는 AreaHeight 속성으로 제어.
		-- PivotOffset이 바닥에 설정되어 있으므로, Size 변경 후 PivotTo로 바닥 위치 고정.
		local height = petMarkerArea:GetAttribute("AreaHeight") or BASE_HEIGHT
		gradientCylinder.Size = Vector3.new(diameter, height, diameter)
		gradientCylinder.PivotOffset = CFrame.new(0, -gradientCylinder.Size.Y / 2, 0)
		gradientCylinder:PivotTo(originalGradientPivot)

		-- NeonRing: 각 RingPart를 새 반지름에 맞춰 재배치 + 세그먼트 길이 스케일
		local centerPos = lightCore.Position
		for _, data in ringParts do
			local newX = centerPos.X + (data.offsetX * scale)
			local newZ = centerPos.Z + (data.offsetZ * scale)
			data.part.Position = Vector3.new(newX, data.originalY, newZ)
			data.part.Size = Vector3.new(data.originalX, data.originalYSize, data.originalZ * scale)
		end

		-- PointLight: 조명 범위를 반지름에 맞춰 조정
		pointLight.Range = diameter
	end

	local currentRadius = petMarkerArea:GetAttribute("AreaRadius")
	if not currentRadius then
		currentRadius = BASE_RADIUS
		petMarkerArea:SetAttribute("AreaRadius", currentRadius)
	end

	local currentHeight = petMarkerArea:GetAttribute("AreaHeight")
	if not currentHeight then
		petMarkerArea:SetAttribute("AreaHeight", BASE_HEIGHT)
	end

	applyRadius(currentRadius)

	local radiusConn = petMarkerArea:GetAttributeChangedSignal("AreaRadius"):Connect(function()
		local newRadius = petMarkerArea:GetAttribute("AreaRadius")
		if newRadius then
			applyRadius(newRadius)
		end
	end)

	local heightConn = petMarkerArea:GetAttributeChangedSignal("AreaHeight"):Connect(function()
		local radius = petMarkerArea:GetAttribute("AreaRadius") or BASE_RADIUS
		applyRadius(radius)
	end)

	return function()
		radiusConn:Disconnect()
		heightConn:Disconnect()
	end
end

return PetMarkerAreaVisualSync
