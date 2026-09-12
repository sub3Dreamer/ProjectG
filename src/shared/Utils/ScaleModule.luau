local ScaleModule = {}

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local GameSettings = require(script.Parent.Parent.Config.GameSettings)
local JumpControl = require(script.Parent.JumpControl)
local CharacterStability = require(script.Parent.CharacterStability)

local PLAYER_SCALE = GameSettings.Scale.PlayerScale

local HUMANOID_BODY_SCALE_NAMES = { "BodyHeightScale", "BodyWidthScale", "BodyDepthScale", "HeadScale" }

local standingAlignConnections: { [Model]: RBXScriptConnection } = {}

type ScaleGuardState = {
	scale: number,
	modelScale: number,
	useBodyScale: boolean,
}

local scaleGuardConnections: { [Model]: { RBXScriptConnection } } = {}
local scaleGuardStateByCharacter: { [Model]: ScaleGuardState } = {}
local scaleGuardCorrectingByCharacter: { [Model]: boolean } = {}

local SCALE_GUARD_EPSILON = 0.01
local SCALE_GUARD_POLL_INTERVAL = 1

local function getScaleConfig()
	local cfg = GameSettings.Scale
	if typeof(cfg) ~= "table" then
		return {
			UseHumanoidBodyScaleForR15 = true,
			StandingGroundAlign = true,
			StandingAlignInterval = 0.12,
			StandingAlignMaxStepStuds = 6,
		}
	end
	return cfg
end

local function getCharacterLevel(character: Model): number
	local level = character:GetAttribute("XPLevel")
	if typeof(level) == "number" and level == level and level >= 1 then
		return math.floor(level + 0.5)
	end
	return 1
end

local function calculateWalkSpeed(level: number): number
	if level <= 1 then
		return 16
	end
	return 16 + 16 * ((level - 1) * 0.5)
end

function ScaleModule.getWalkSpeedForLevel(level: number): number
	return calculateWalkSpeed(level)
end

local function getFeverMoveSpeedMultiplier(character: Model): number
	local cfg = GameSettings.Combat.FeverMode
	if typeof(cfg) ~= "table" then
		return 1
	end
	if character:GetAttribute("FeverMode") ~= true then
		return 1
	end
	local m = cfg.MoveSpeedMultiplier
	if typeof(m) == "number" and m == m and m > 0 then
		return m
	end
	return 1
end

local function getMoveSpeedUpMultiplier(character: Model): number
	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return 1
	end
	local percent = player:GetAttribute("MoveSpeedUpPercent")
	if typeof(percent) ~= "number" or percent <= 0 then
		return 1
	end
	return 1 + percent / 100
end

function ScaleModule.applyWalkSpeedForCharacter(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local level = getCharacterLevel(character)
	local mult = getFeverMoveSpeedMultiplier(character)
	local moveSpeedUpMult = getMoveSpeedUpMultiplier(character)
	humanoid.WalkSpeed = calculateWalkSpeed(level) * mult * moveSpeedUpMult
end

function ScaleModule.getCharacterScale(character: Model): number
	local attr = character:GetAttribute("CharacterScale")
	if typeof(attr) == "number" and attr == attr and attr > 0 then
		return attr
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R15 then
		local bodyHeight = humanoid:FindFirstChild("BodyHeightScale")
		if bodyHeight and bodyHeight:IsA("NumberValue") then
			local v = bodyHeight.Value
			if v > 0 then
				return v
			end
		end
	end

	local ok, value = pcall(function()
		return character:GetScale()
	end)
	if ok and typeof(value) == "number" and value == value and value > 0 then
		return value
	end
	return PLAYER_SCALE
end

local function isR15Humanoid(humanoid: Humanoid): boolean
	return humanoid.RigType == Enum.HumanoidRigType.R15
end

local function setCharacterScaleAttribute(character: Model, scale: number)
	character:SetAttribute("CharacterScale", scale)
end

local function applyR15HumanoidBodyScale(humanoid: Humanoid, targetScale: number)
	for _, name in HUMANOID_BODY_SCALE_NAMES do
		local nv = humanoid:FindFirstChild(name)
		if nv and nv:IsA("NumberValue") then
			nv.Value = targetScale
		end
	end
end

local function resetModelScaleIfNeeded(character: Model)
	local ok, modelScale = pcall(function()
		return character:GetScale()
	end)
	if not ok or typeof(modelScale) ~= "number" then
		return
	end
	if math.abs(modelScale - PLAYER_SCALE) < 0.01 then
		return
	end
	pcall(function()
		character:ScaleTo(PLAYER_SCALE)
	end)
end

local function getR15FootBottomY(character: Model): number?
	local leftFoot = character:FindFirstChild("LeftFoot")
	local rightFoot = character:FindFirstChild("RightFoot")
	if leftFoot and leftFoot:IsA("BasePart") and rightFoot and rightFoot:IsA("BasePart") then
		local leftBottom = leftFoot.Position.Y - leftFoot.Size.Y / 2
		local rightBottom = rightFoot.Position.Y - rightFoot.Size.Y / 2
		return math.min(leftBottom, rightBottom)
	end
	return nil
end

local function alignR15FeetToGround(character: Model, humanoid: Humanoid, humanoidRootPart: BasePart)
	local footBottomY = getR15FootBottomY(character)
	if footBottomY == nil then
		return
	end

	local cfg = getScaleConfig()
	local maxStep = cfg.StandingAlignMaxStepStuds or 6

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }

	local origin = Vector3.new(humanoidRootPart.Position.X, footBottomY + 2, humanoidRootPart.Position.Z)
	local result = workspace:Raycast(origin, Vector3.new(0, -32, 0), rayParams)
	if not result then
		return
	end

	local deltaY = result.Position.Y - footBottomY
	if math.abs(deltaY) < 0.05 then
		return
	end

	deltaY = math.clamp(deltaY, -maxStep, maxStep)
	humanoidRootPart.CFrame = humanoidRootPart.CFrame + Vector3.new(0, deltaY, 0)
end

local function stopStandingGroundAlign(character: Model)
	local conn = standingAlignConnections[character]
	if conn then
		conn:Disconnect()
		standingAlignConnections[character] = nil
	end
end

local function startStandingGroundAlign(character: Model, humanoid: Humanoid, humanoidRootPart: BasePart)
	stopStandingGroundAlign(character)

	local cfg = getScaleConfig()
	if cfg.StandingGroundAlign == false then
		return
	end
	if not isR15Humanoid(humanoid) then
		return
	end

	local interval = cfg.StandingAlignInterval or 0.12
	local elapsed = 0

	standingAlignConnections[character] = RunService.Heartbeat:Connect(function(dt)
		if not character.Parent then
			stopStandingGroundAlign(character)
			return
		end

		elapsed += dt
		if elapsed < interval then
			return
		end
		elapsed = 0

		if humanoid.MoveDirection.Magnitude > 0.1 then
			return
		end

		local state = humanoid:GetState()
		if state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping then
			return
		end

		alignR15FeetToGround(character, humanoid, humanoidRootPart)
	end)

	character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			stopStandingGroundAlign(character)
		end
	end)
end

local function scaleR15Character(
	character: Model,
	humanoid: Humanoid,
	humanoidRootPart: BasePart,
	scale: number
)
	local cfg = getScaleConfig()
	if cfg.UseHumanoidBodyScaleForR15 ~= false then
		-- 리사이즈~재접지 구간 동안 캐릭터를 고정(R6 경로와 동일한 패턴): 몸이 커지는 순간부터
		-- 재접지 전까지 unanchored 상태로 방치하면 주변 지오메트리에 파묻혀 물리 솔버가 겹침을
		-- 풀어내며 캐릭터를 튕겨낼 수 있다(레벨업 리스케일 중 플레이어 승천 버그의 원인).
		humanoidRootPart.Anchored = true
		resetModelScaleIfNeeded(character)
		applyR15HumanoidBodyScale(humanoid, scale)
		setCharacterScaleAttribute(character, scale)
		task.wait(0.15)
		alignR15FeetToGround(character, humanoid, humanoidRootPart)
		humanoidRootPart.Anchored = false
		startStandingGroundAlign(character, humanoid, humanoidRootPart)
		return true
	end

	-- 폴백: Model:ScaleTo
	local ok, err = pcall(function()
		character:ScaleTo(scale)
	end)
	if not ok then
		warn("[ScaleModule] Model:ScaleTo 실패:", err)
		return false
	end
	setCharacterScaleAttribute(character, scale)
	task.wait(0.1)
	alignR15FeetToGround(character, humanoid, humanoidRootPart)
	startStandingGroundAlign(character, humanoid, humanoidRootPart)
	return true
end

local function scaleR6Character(
	character: Model,
	humanoidRootPart: BasePart,
	scale: number,
	currentScale: number
)
	local currentHeight = character:GetExtentsSize().Y
	local footY = humanoidRootPart.Position.Y - (currentHeight / 2)
	local isGrowing = scale > currentScale

	humanoidRootPart.Anchored = true

	if isGrowing then
		local expectedHeight = currentHeight * (scale / currentScale)
		local heightDiff = expectedHeight - currentHeight
		humanoidRootPart.CFrame = humanoidRootPart.CFrame + Vector3.new(0, heightDiff / 2, 0)
	end

	local ok, err = pcall(function()
		character:ScaleTo(scale)
	end)
	if not ok then
		humanoidRootPart.Anchored = false
		warn("[ScaleModule] Model:ScaleTo 실패:", err)
		return false
	end

	task.wait(0.1)

	if not isGrowing then
		local newHeight = character:GetExtentsSize().Y
		humanoidRootPart.CFrame = CFrame.new(
			humanoidRootPart.Position.X,
			footY + newHeight / 2,
			humanoidRootPart.Position.Z
		) * (humanoidRootPart.CFrame - humanoidRootPart.CFrame.Position)
	end

	humanoidRootPart.Anchored = false
	humanoidRootPart.AssemblyLinearVelocity = Vector3.zero
	setCharacterScaleAttribute(character, scale)
	return true
end

local function stopScaleGuard(character: Model)
	local connections = scaleGuardConnections[character]
	if connections then
		for _, conn in connections do
			conn:Disconnect()
		end
		scaleGuardConnections[character] = nil
	end
	scaleGuardStateByCharacter[character] = nil
	scaleGuardCorrectingByCharacter[character] = nil
end

--- 익스플로잇이 클라이언트에서 BodyHeightScale류 NumberValue, Model.Scale, CharacterScale
--- 속성을 직접 건드려 아바타 크기를 위조하는 것을 막기 위한 서버 측 감시. 서버가 마지막으로
--- 적용한 값과 어긋나면 즉시 되돌린다.
local function correctScaleDrift(character: Model, humanoid: Humanoid)
	local state = scaleGuardStateByCharacter[character]
	if not state or scaleGuardCorrectingByCharacter[character] then
		return
	end

	local bodyDrifted = false
	if state.useBodyScale then
		for _, name in HUMANOID_BODY_SCALE_NAMES do
			local nv = humanoid:FindFirstChild(name)
			if nv and nv:IsA("NumberValue") and math.abs(nv.Value - state.scale) > SCALE_GUARD_EPSILON then
				bodyDrifted = true
				break
			end
		end
	end

	local ok, modelScale = pcall(function()
		return character:GetScale()
	end)
	local modelDrifted = ok and typeof(modelScale) == "number" and math.abs(modelScale - state.modelScale) > SCALE_GUARD_EPSILON

	local attr = character:GetAttribute("CharacterScale")
	local attrDrifted = typeof(attr) == "number" and math.abs(attr - state.scale) > SCALE_GUARD_EPSILON

	if not bodyDrifted and not modelDrifted and not attrDrifted then
		return
	end

	scaleGuardCorrectingByCharacter[character] = true

	local player = Players:GetPlayerFromCharacter(character)
	warn(string.format(
		"[ScaleModule] 스케일 변조 감지 (%s, %s) — %.3f 로 강제 복원",
		character.Name,
		player and ("UserId " .. tostring(player.UserId)) or "no player",
		state.scale
	))

	if state.useBodyScale then
		applyR15HumanoidBodyScale(humanoid, state.scale)
	end
	if modelDrifted then
		pcall(function()
			character:ScaleTo(state.modelScale)
		end)
	end
	setCharacterScaleAttribute(character, state.scale)

	scaleGuardCorrectingByCharacter[character] = false
end

local function startScaleGuard(character: Model, humanoid: Humanoid, scale: number)
	stopScaleGuard(character)

	local cfg = getScaleConfig()
	local useBodyScale = isR15Humanoid(humanoid) and cfg.UseHumanoidBodyScaleForR15 ~= false
	scaleGuardStateByCharacter[character] = {
		scale = scale,
		modelScale = if useBodyScale then PLAYER_SCALE else scale,
		useBodyScale = useBodyScale,
	}

	local connections = {}

	if useBodyScale then
		for _, name in HUMANOID_BODY_SCALE_NAMES do
			local nv = humanoid:FindFirstChild(name)
			if nv and nv:IsA("NumberValue") then
				table.insert(
					connections,
					nv.Changed:Connect(function()
						correctScaleDrift(character, humanoid)
					end)
				)
			end
		end
	end

	table.insert(
		connections,
		character:GetAttributeChangedSignal("CharacterScale"):Connect(function()
			correctScaleDrift(character, humanoid)
		end)
	)

	local elapsed = 0
	table.insert(
		connections,
		RunService.Heartbeat:Connect(function(dt)
			if not character.Parent then
				stopScaleGuard(character)
				return
			end
			elapsed += dt
			if elapsed < SCALE_GUARD_POLL_INTERVAL then
				return
			end
			elapsed = 0
			correctScaleDrift(character, humanoid)
		end)
	)

	table.insert(
		connections,
		character.AncestryChanged:Connect(function(_, parent)
			if not parent then
				stopScaleGuard(character)
			end
		end)
	)

	scaleGuardConnections[character] = connections
end

function ScaleModule.setCharacterScale(character: Model, targetScale: number?)
	local scale = targetScale or PLAYER_SCALE

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")

	if not (humanoid and humanoidRootPart and humanoidRootPart:IsA("BasePart")) then
		warn("[ScaleModule] Humanoid 또는 HumanoidRootPart를 찾지 못함")
		return false
	end

	stopStandingGroundAlign(character)
	stopScaleGuard(character)

	local currentScale = ScaleModule.getCharacterScale(character)
	local ok: boolean
	if isR15Humanoid(humanoid) then
		ok = scaleR15Character(character, humanoid, humanoidRootPart, scale)
	else
		ok = scaleR6Character(character, humanoidRootPart, scale, currentScale)
	end

	if not ok then
		return false
	end

	if isR15Humanoid(humanoid) then
		humanoidRootPart.AssemblyLinearVelocity = Vector3.zero
		humanoidRootPart.AssemblyAngularVelocity = Vector3.zero
	end

	ScaleModule.applyWalkSpeedForCharacter(character)
	JumpControl.applyToHumanoid(humanoid)
	CharacterStability.apply(character)
	startScaleGuard(character, humanoid, scale)

	local cameraDistance = GameSettings.Camera.BaseDistance + (scale - 1) * GameSettings.Camera.DistancePerScale
	print(
		"[ScaleModule] 캐릭터 스케일 설정 완료:",
		character.Name,
		"스케일:",
		scale,
		"카메라 거리:",
		string.format("%.1f", cameraDistance)
	)
	return true
end

function ScaleModule.setupForPlayer(player: Player, getScale: (() -> number)?)
	local function apply(character: Model)
		task.wait(0.1)
		local target = (getScale and getScale()) or PLAYER_SCALE
		ScaleModule.setCharacterScale(character, target)
	end

	player.CharacterAdded:Connect(apply)

	if player.Character then
		task.spawn(function()
			apply(player.Character)
		end)
	end
end

return ScaleModule
