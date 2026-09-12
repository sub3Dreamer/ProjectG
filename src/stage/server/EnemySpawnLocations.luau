--[[
	Workspace 아래 SpawnLocation마다:
	• Attribute EnemyModelName = ReplicatedStorage.Enemies 안 Model 이름 (예: BlackSoldier)
	• 플레이어가 반경 안에 들어오면 해당 위치에 적 1회 생성

	늦게 붙는 인스턴스는 DescendantAdded + 짧은 지연 재스캔으로 등록한다.
]]

local EnemySpawnLocations = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local EnemySetup = require(script.Parent.enemy.EnemySetup)
local CombatHandler = require(script.Parent.CombatHandler)

local TRIGGER_RADIUS_STUDS = 50
local ZONE_POLL_SEC = 0.12
local RESCAN_DELAY_SEC = 0.35
--- 속성/스트리밍 지연 후에도 슬롯을 놓치지 않도록 주기적으로 다시 스캔
local RESCAN_INTERVAL_SEC = 2.5

type SlotState = {
	spawnLocation: SpawnLocation,
	code: string,
	zone: Part,
	consumed: boolean,
}

local function readEnemyCode(inst: Instance): string?
	local codeRaw = inst:GetAttribute(EnemySetup.AttributeName)
	if typeof(codeRaw) ~= "string" then
		return nil
	end
	local trimmed = EnemySetup.trim(codeRaw :: string)
	if trimmed == "" then
		return nil
	end
	return trimmed
end

local function createZoneVisual(spawnLocation: SpawnLocation): Part
	local diameter = TRIGGER_RADIUS_STUDS * 2
	local p = Instance.new("Part")
	p.Name = "EnemySpawnZoneVisual"
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(diameter, diameter, diameter)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CastShadow = false
	p.Material = Enum.Material.ForceField
	p.Color = Color3.fromRGB(255, 215, 55)
	p.Transparency = 0.7
	p.CFrame = spawnLocation:GetPivot()
	p.Parent = Workspace
	return p
end

-- 디브리 큐브가 건물 잔해에 파묻혔다 튕겨나가며 근처 NPC를 밀치는 경로로 플레이어에게 힘이
-- 전달되는 것을 막기 위해, NPC도 플레이어와 동일하게 디브리와 충돌하지 않는 그룹에 넣는다.
local function unanchorModel(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CollisionGroup = CombatHandler.EnemyCollisionGroup
		end
	end
end

--- 발판 파트 윗면 중심(로컬 +Y)
local function getSpawnTopFaceCFrame(surfacePart: BasePart): CFrame
	return surfacePart.CFrame * CFrame.new(0, surfacePart.Size.Y * 0.5, 0)
end

--- 월드 축 AABB 기준: 발(박스 하단)이 윗면에 닿도록 Y 보정, XZ는 윗면 중심에 맞춤
local FOOT_SURFACE_GAP = 0.08

local function alignModelFeetOnSpawnTop(model: Model, topFaceCf: CFrame)
	model:PivotTo(topFaceCf)
	local ok, cf, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if not ok or typeof(cf) ~= "CFrame" or typeof(size) ~= "Vector3" then
		return
	end
	if size.X < 1e-4 or size.Y < 1e-4 or size.Z < 1e-4 then
		return
	end
	local bottomY = cf.Position.Y - size.Y * 0.5
	local targetFootY = topFaceCf.Position.Y + FOOT_SURFACE_GAP
	local dy = targetFootY - bottomY
	local dx = topFaceCf.Position.X - cf.Position.X
	local dz = topFaceCf.Position.Z - cf.Position.Z
	if math.abs(dx) > 1e-6 or math.abs(dy) > 1e-6 or math.abs(dz) > 1e-6 then
		model:PivotTo(CFrame.new(dx, dy, dz) * model:GetPivot())
	end
end

local function spawnOneAt(template: Model, spawnLocation: SpawnLocation, code: string)
	local clone = template:Clone()
	clone.Name = code .. "_" .. tostring(os.clock()) .. "_" .. tostring(math.random(100000, 999999))
	clone.Parent = Workspace
	local topFaceCf = getSpawnTopFaceCFrame(spawnLocation)
	alignModelFeetOnSpawnTop(clone, topFaceCf)
	unanchorModel(clone)
	EnemySetup.setup(code, clone)
end

local function consumeSlot(st: SlotState)
	if st.zone.Parent then
		st.zone:Destroy()
	end
	st.consumed = true
end

--- 스폰 구(반경 R)와 캐릭터 일부가 겹치면 true. HRP만 보면 거대화 시 발/팔이 구 안에 있어도 놓친다.
local function characterIntersectsSpawnSphere(character: Model, sphereCenter: Vector3, sphereRadius: number): boolean
	for _, inst in character:GetDescendants() do
		if inst:IsA("BasePart") then
			local part = inst :: BasePart
			local partExtent = part.Size.Magnitude * 0.5
			if (part.Position - sphereCenter).Magnitude <= sphereRadius + partExtent then
				return true
			end
		end
	end
	return false
end

function EnemySpawnLocations.init()
	local enemiesFolder = ReplicatedStorage:FindFirstChild("Enemies") or ReplicatedStorage:WaitForChild("Enemies", 30)
	if not enemiesFolder then
		warn("[EnemySpawnLocations] ReplicatedStorage.Enemies 없음 — 스폰 비활성")
		return
	end

	-- Instance 키(서브클래스 타입 키 테이블 이슈 회피 + 일관성)
	local tracked: { [Instance]: boolean } = {}
	local attributeHooked: { [Instance]: boolean } = {}
	local states: { SlotState } = {}

	local function registerSlot(spawnLocation: SpawnLocation, code: string): boolean
		if tracked[spawnLocation] then
			return false
		end
		tracked[spawnLocation] = true
		table.insert(states, {
			spawnLocation = spawnLocation,
			code = code,
			zone = createZoneVisual(spawnLocation),
			consumed = false,
		})
		print("[EnemySpawnLocations] 등록:", spawnLocation:GetFullName(), "→", code, "| 총", #states, "개")
		return true
	end

	local function tryRegister(inst: Instance)
		if not inst:IsDescendantOf(Workspace) then
			return
		end
		if not inst:IsA("SpawnLocation") then
			return
		end
		local spawnLocation = inst :: SpawnLocation
		if tracked[spawnLocation] then
			return
		end
		local code = readEnemyCode(spawnLocation)
		if not code then
			return
		end
		registerSlot(spawnLocation, code)
	end

	local function hookSpawnLocationAttributes(sl: SpawnLocation)
		if attributeHooked[sl] then
			return
		end
		attributeHooked[sl] = true
		sl:GetAttributeChangedSignal(EnemySetup.AttributeName):Connect(function()
			task.defer(function()
				tryRegister(sl)
			end)
		end)
	end

	local function scanWorkspaceSpawnLocations()
		for _, d in Workspace:GetDescendants() do
			if d:IsA("SpawnLocation") then
				local sl = d :: SpawnLocation
				hookSpawnLocationAttributes(sl)
				tryRegister(sl)
			end
		end
	end

	local initialScanStartClock = os.clock()
	scanWorkspaceSpawnLocations()
	print(string.format("[EnemySpawnLocations] 최초 스캔 완료: 슬롯 %d개 (%.2f초 소요)", #states, os.clock() - initialScanStartClock))

	Workspace.DescendantAdded:Connect(function(inst: Instance)
		if not inst:IsA("SpawnLocation") then
			return
		end
		local sl = inst :: SpawnLocation
		hookSpawnLocationAttributes(sl)
		task.defer(function()
			task.wait()
			tryRegister(sl)
		end)
	end)

	task.delay(RESCAN_DELAY_SEC, function()
		scanWorkspaceSpawnLocations()
		print("[EnemySpawnLocations] 지연 재스캔 완료 — 슬롯 총", #states, "개")
	end)

	task.spawn(function()
		while true do
			task.wait(RESCAN_INTERVAL_SEC)
			scanWorkspaceSpawnLocations()
		end
	end)

	if #states == 0 then
		warn("[EnemySpawnLocations] 슬롯 0개. SpawnLocation에 EnemyModelName(문자열)을 넣었는지 확인.")
	end

	task.spawn(function()
		-- task.spawn은 이 함수를 "즉시" 동기 실행하고 첫 yield에서야 호출부로 돌아간다. 아래
		-- while문 몸체가 첫 바퀴부터 states 전체 × 플레이어 캐릭터 GetDescendants() 스캔을
		-- 돌기 때문에, 이 task.wait()가 없으면 EnemySpawnLocations.init()(과 그 뒤 전체
		-- 서버 부팅 순서)이 states 개수에 비례해 블로킹된다.
		task.wait()
		while true do
			local pending = 0
			for _, st in states do
				if not st.consumed then
					pending += 1
				end
			end

			if pending == 0 then
				task.wait(#states == 0 and 0.25 or ZONE_POLL_SEC)
				continue
			end

			for _, st in states do
				if st.consumed then
					continue
				end
				local spawnLocation = st.spawnLocation
				if not spawnLocation.Parent then
					consumeSlot(st)
					continue
				end

				st.zone.CFrame = spawnLocation:GetPivot()

				local center = spawnLocation:GetPivot().Position
				local triggered = false
				for _, plr in Players:GetPlayers() do
					local ch = plr.Character
					if ch and ch:IsA("Model") and characterIntersectsSpawnSphere(ch, center, TRIGGER_RADIUS_STUDS) then
						triggered = true
						break
					end
				end

				if triggered then
					local code = st.code
					if not EnemySetup.isRegistered(code) then
						warn("[EnemySpawnLocations] EnemyModelName 미등록 — 스킵:", code, "|", spawnLocation:GetFullName())
						consumeSlot(st)
					else
						local template = enemiesFolder:FindFirstChild(code)
						if template and template:IsA("Model") then
							spawnOneAt(template, spawnLocation, code)
							consumeSlot(st)
						else
							warn("[EnemySpawnLocations] Enemies에 Model 없음:", code, "|", spawnLocation:GetFullName())
							consumeSlot(st)
						end
					end
				end
			end

			task.wait(ZONE_POLL_SEC)
		end
	end)
end

return EnemySpawnLocations
