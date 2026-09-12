--[[
	Workspace 아래 Model 중 HitPoint config + Tier가 있는 오브젝트를
	서버 기동 시 스냅샷해 두고, Reset 시 해당 경로의 인스턴스를 제거한 뒤 복제본을 다시 붙인다.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DamageableObjectStats = require(Shared.Utils.DamageableObjectStats)

local DamageableWorkspaceReset = {}

local function isSnapshotTarget(model: Model): boolean
	return DamageableObjectStats.tierOnModel(model) ~= nil and DamageableObjectStats.hasDamageableConfig(model)
end

local function getInstanceByFullName(fullName: string): Instance?
	if fullName == "Workspace" then
		return Workspace
	end
	local prefix = "Workspace."
	if string.sub(fullName, 1, #prefix) ~= prefix then
		return nil
	end
	local rest = string.sub(fullName, #prefix + 1)
	if rest == "" then
		return Workspace
	end
	local current: Instance = Workspace
	for segment in string.gmatch(rest, "[^%.]+") do
		local nextInst = current:FindFirstChild(segment)
		if not nextInst then
			return nil
		end
		current = nextInst
	end
	return current
end

type SnapshotEntry = {
	fullName: string,
	parentFullName: string,
	template: Model,
}

local snapshots: { SnapshotEntry } = {}

function DamageableWorkspaceReset.init()
	table.clear(snapshots)

	local n = 0
	for _, inst in Workspace:GetDescendants() do
		if not inst:IsA("Model") then
			continue
		end
		if not isSnapshotTarget(inst) then
			continue
		end
		if not inst.Archivable then
			warn("[DamageableWorkspaceReset] Skip non-Archivable:", inst:GetFullName())
			continue
		end

		local template = inst:Clone()
		table.insert(snapshots, {
			fullName = inst:GetFullName(),
			parentFullName = inst.Parent:GetFullName(),
			template = template,
		})
		n += 1
	end

	if n > 0 then
		print("[DamageableWorkspaceReset] Snapshotted", n, "Tier+HitPoint Model(s) under Workspace")
	end
end

function DamageableWorkspaceReset.restoreFromSnapshots(): (boolean, string?, number)
	if #snapshots == 0 then
		return true, nil, 0
	end

	local restored = 0
	for _, entry in ipairs(snapshots) do
		local parent = getInstanceByFullName(entry.parentFullName)
		if not parent then
			warn("[DamageableWorkspaceReset] Parent missing, skip:", entry.parentFullName)
			continue
		end

		local existing = getInstanceByFullName(entry.fullName)
		if existing and existing.Parent then
			existing:Destroy()
		end

		local fresh = entry.template:Clone()
		fresh.Parent = parent
		restored += 1
	end

	if restored == 0 then
		return false, "damageable_nothing_restored", 0
	end

	return true, nil, restored
end

return DamageableWorkspaceReset
