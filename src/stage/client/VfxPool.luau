--[[
	클라이언트 폭발·타격 VFX 풀. 템플릿 Clone/Destroy 스파이크 완화.
	풀이 비면 추가 Clone 후 사용, lifetime 종료 시 회수.
]]

local POOLED_ATTRIBUTE = "PooledVfxTemplate"

local VfxPool = {}

type PoolState = {
	templateName: string,
	available: { Instance },
}

local stashFolder: Folder? = nil
local poolsByTemplate: { [string]: PoolState } = {}
local createFromTemplate: ((string, Instance) -> Instance?)? = nil

local STASH_CFRAME = CFrame.new(0, -5000, 0)

local function resetVfxScale(root: Instance)
	local function scaleOne(model: Model)
		pcall(function()
			model:ScaleTo(1)
		end)
	end

	if root:IsA("Model") then
		scaleOne(root)
	elseif root:IsA("Folder") then
		for _, ch in root:GetChildren() do
			if ch:IsA("Model") then
				scaleOne(ch)
			end
		end
	end
end

local function pivotVfxRoot(root: Instance, cf: CFrame)
	if root:IsA("Model") then
		root:PivotTo(cf)
	elseif root:IsA("Folder") then
		for _, ch in root:GetChildren() do
			if ch:IsA("Model") then
				ch:PivotTo(cf)
			end
		end
	end
end

local function stopParticleEmitters(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			d.Enabled = false
			d.Rate = 0
		end
	end
end

function VfxPool.init(createFn: (string, Instance) -> Instance?)
	createFromTemplate = createFn

	if stashFolder then
		stashFolder:Destroy()
	end

	stashFolder = Instance.new("Folder")
	stashFolder.Name = "PooledVfxStash"
	stashFolder.Parent = nil

	for key in poolsByTemplate do
		poolsByTemplate[key] = nil
	end
end

function VfxPool.register(templateName: string, template: Instance, prewarmCount: number)
	if templateName == "" or not template then
		return
	end
	if not createFromTemplate or not stashFolder then
		warn("[VfxPool] init() before register()")
		return
	end

	local state: PoolState = {
		templateName = templateName,
		available = {},
	}
	poolsByTemplate[templateName] = state

	for _ = 1, math.max(0, prewarmCount) do
		local inst = createFromTemplate(templateName, template)
		if inst then
			inst:SetAttribute(POOLED_ATTRIBUTE, templateName)
			stopParticleEmitters(inst)
			pivotVfxRoot(inst, STASH_CFRAME)
			inst.Parent = stashFolder
			table.insert(state.available, inst)
		end
	end
end

function VfxPool.isRegistered(templateName: string): boolean
	return poolsByTemplate[templateName] ~= nil
end

function VfxPool.acquire(templateName: string, template: Instance, cf: CFrame): Instance?
	if not createFromTemplate or not stashFolder then
		return nil
	end

	local state = poolsByTemplate[templateName]
	if not state then
		return nil
	end

	local root: Instance?
	if #state.available > 0 then
		root = table.remove(state.available)
	else
		root = createFromTemplate(templateName, template)
		if root then
			root:SetAttribute(POOLED_ATTRIBUTE, templateName)
		end
	end

	if not root then
		return nil
	end

	stopParticleEmitters(root)
	resetVfxScale(root)
	pivotVfxRoot(root, cf)
	root.Parent = workspace
	return root
end

function VfxPool.release(root: Instance)
	if not stashFolder or not root then
		return
	end

	local templateName = root:GetAttribute(POOLED_ATTRIBUTE)
	if typeof(templateName) ~= "string" or templateName == "" then
		root:Destroy()
		return
	end

	local state = poolsByTemplate[templateName]
	if not state then
		root:Destroy()
		return
	end

	stopParticleEmitters(root)
	resetVfxScale(root)
	pivotVfxRoot(root, STASH_CFRAME)
	root.Parent = stashFolder
	table.insert(state.available, root)
end

function VfxPool.availableCount(templateName: string): number
	local state = poolsByTemplate[templateName]
	if not state then
		return 0
	end
	return #state.available
end

return VfxPool
