--[[
	Pre-allocated debris cubes under ServerStorage. Acquire on hit, release after lifetime.
	Avoids Instance.new/Destroy spikes during combat.
	풀이 비면 동일 설정으로 Part를 추가 생성해 반환(총량은 release 시 available로 회수되며 증가).
]]

local ServerStorage = game:GetService("ServerStorage")

local DebrisPool = {}

local poolFolder: Folder
local available: { BasePart } = {}

local storedCubeSize: number = 0.35
local storedCollisionGroup: string = "Default"
local storedPhysicalProperties: PhysicalProperties = PhysicalProperties.new(0.9, 0.42, 0.25)
local nextSlotIndex = 0

local function createPartInternal(): BasePart
	nextSlotIndex += 1
	local sizeVec = Vector3.new(storedCubeSize, storedCubeSize, storedCubeSize)
	local p = Instance.new("Part")
	p.Name = "PooledDebris"
	p.Size = sizeVec
	p.Material = Enum.Material.Plastic
	p.Anchored = true
	p.CanCollide = false
	p.Transparency = 1
	p.CollisionGroup = storedCollisionGroup
	p.CustomPhysicalProperties = storedPhysicalProperties
	p.CFrame = CFrame.new(0, -5000 + nextSlotIndex * 0.02, 0)
	p.Parent = poolFolder
	return p
end

function DebrisPool.init(poolSize: number, cubeSize: number, collisionGroup: string, physicalProperties: PhysicalProperties)
	local existing = ServerStorage:FindFirstChild("DebrisCubePool")
	if existing then
		existing:Destroy()
	end

	while #available > 0 do
		table.remove(available)
	end

	poolFolder = Instance.new("Folder")
	poolFolder.Name = "DebrisCubePool"
	poolFolder.Parent = ServerStorage

	storedCubeSize = cubeSize
	storedCollisionGroup = collisionGroup
	storedPhysicalProperties = physicalProperties
	nextSlotIndex = 0

	for _ = 1, poolSize do
		table.insert(available, createPartInternal())
	end
end

function DebrisPool.acquire(): BasePart?
	if not poolFolder then
		return nil
	end
	if #available > 0 then
		return table.remove(available)
	end
	return createPartInternal()
end

function DebrisPool.release(p: BasePart)
	if not p or p.Name ~= "PooledDebris" or not poolFolder then
		return
	end
	if p.Parent == poolFolder then
		return
	end

	p.AssemblyLinearVelocity = Vector3.zero
	p.AssemblyAngularVelocity = Vector3.zero
	p.Anchored = true
	p.CanCollide = false
	p.Transparency = 1
	p.Parent = poolFolder
	table.insert(available, p)
end

function DebrisPool.availableCount(): number
	return #available
end

function DebrisPool.totalPartCount(): number
	return nextSlotIndex
end

return DebrisPool
