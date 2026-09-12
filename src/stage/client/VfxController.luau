--[[
	Client VFX: ReplicatedStorage Model (or Folder of Models) -> Workspace, optional ScaleTo, particle Emit burst, cleanup.
	Wires ExplodeVfxEvent + HitFxEvent. 폭발·타격 VFX는 VfxPool 재활용.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameSettings = require(Shared.Config.GameSettings)
local SoundManager = require(Shared.Managers.SoundManager)
local VfxPool = require(script.Parent.VfxPool)
local HitFxVisibility = require(script.Parent.HitFxVisibility)

local VfxController = {}

local effectTemplatesByName: { [string]: Instance } = {}

-- GameSettings.Scale.MinScale(=1)은 "플레이어 캐릭터가 이보다 작아지지 않는다"는 의미라
-- 펫처럼 원래 1보다 작은 존재가 낸 HitFx까지 여기에 맞춰 최소 1로 눌러버리면 안 된다.
-- HitFx 자체의 상식적인 하한선(너무 작아 안 보이거나 NaN 방지)만 별도로 둔다.
local HITFX_MIN_SCALE = 0.05

local function computeHitFxZOffset(attackerLevel: number?): number
	local level = attackerLevel
	if typeof(level) ~= "number" or level ~= level or level < 1 then
		level = 1
	end
	level = math.floor(level + 0.5)

	local c = GameSettings.Combat
	local perLevelLow = c.HitFxZOffsetPerLevelLow
	if typeof(perLevelLow) ~= "number" or perLevelLow ~= perLevelLow then
		perLevelLow = 5
	end
	local perLevelHigh = c.HitFxZOffsetPerLevelHigh
	if typeof(perLevelHigh) ~= "number" or perLevelHigh ~= perLevelHigh then
		perLevelHigh = 10
	end
	local tierSplit = c.HitFxZOffsetLevelTierSplit
	if typeof(tierSplit) ~= "number" or tierSplit ~= tierSplit then
		tierSplit = 5
	end

	if level <= tierSplit then
		return level * perLevelLow
	end
	return level * perLevelHigh
end

--- 캐릭터 회전과 무관하게 이펙트가 항상 카메라를 정면(-Z)으로 바라보도록 회전만 교체(위치는 유지).
--- 파티클 발사 방향(Attachment 로컬 축 기준)이 공격자 방향을 따라 돌아가 버리는 것을 막기 위함.
local function billboardTowardCamera(position: Vector3): CFrame
	local cam = Workspace.CurrentCamera
	if not cam then
		return CFrame.new(position)
	end
	local camPos = cam.CFrame.Position
	if (camPos - position).Magnitude < 1e-3 then
		return CFrame.new(position)
	end
	return CFrame.lookAt(position, camPos)
end

local function applyCharacterScaleToModels(root, scale)
	if scale == 1 or scale ~= scale or scale <= 0 then
		return
	end

	local function scaleOne(model)
		local ok, err = pcall(function()
			model:ScaleTo(scale)
		end)
		if not ok then
			warn("[VfxController] Model:ScaleTo failed:", model:GetFullName(), err)
		end
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

local function syncVfxRootToPart(root: Instance, part: BasePart)
	local cf = part:GetPivot()
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

local function releaseVfxRoot(root: Instance, usePool: boolean)
	if usePool then
		VfxPool.release(root)
	elseif root.Parent then
		root:Destroy()
	end
end

local function scheduleEmitAndCleanup(
	root: Instance,
	particleEmitCount: number,
	lifetime: number,
	followPart: BasePart?,
	usePool: boolean,
	particleZOffset: number?
)
	task.defer(function()
		for _, d in root:GetDescendants() do
			if d:IsA("ParticleEmitter") then
				d.Rate = 0
				d.Enabled = true
				if typeof(particleZOffset) == "number" and particleZOffset == particleZOffset then
					d.ZOffset = particleZOffset
				end
				d:Emit(particleEmitCount)
				d.Enabled = false
			end
		end
	end)

	local followConn: RBXScriptConnection? = nil
	if followPart then
		syncVfxRootToPart(root, followPart)
		followConn = RunService.RenderStepped:Connect(function()
			if not followPart.Parent then
				if followConn then
					followConn:Disconnect()
				end
				releaseVfxRoot(root, usePool)
				return
			end
			if root.Parent then
				syncVfxRootToPart(root, followPart)
			end
		end)
	end

	task.delay(lifetime, function()
		if followConn then
			followConn:Disconnect()
		end
		if root.Parent then
			releaseVfxRoot(root, usePool)
		end
	end)
end

local function findEffectTemplate(templateName: string): Instance?
	if not templateName or templateName == "" then
		return nil
	end
	local c = GameSettings.Combat
	local folderName = c.EffectsFolderName or "Effects"
	local effectsFolder = ReplicatedStorage:FindFirstChild(folderName)
	local template = effectsFolder and effectsFolder:FindFirstChild(templateName)
	if not template then
		template = ReplicatedStorage:FindFirstChild(templateName)
	end
	return template
end

local function createPooledVfxFromTemplate(_templateName: string, template: Instance): Instance?
	if template:IsA("Model") then
		local fx = template:Clone()
		fx.Name = "PooledVfx"
		return fx
	elseif template:IsA("Folder") then
		local wrap = Instance.new("Folder")
		wrap.Name = "PooledVfx"
		for _, child in template:GetChildren() do
			if child:IsA("Model") then
				child:Clone().Parent = wrap
			end
		end
		return wrap
	end
	warn("[VfxController] Template must be a Model or Folder of Models:", template.Name)
	return nil
end

local function cloneEffectTemplateToWorkspace(templateName: string, cf: CFrame): Instance?
	local template = findEffectTemplate(templateName)
	if not template then
		local c = GameSettings.Combat
		warn(
			"[VfxController] VFX 템플릿 없음:",
			(c.EffectsFolderName or "Effects") .. "/" .. templateName,
			"또는 ReplicatedStorage 직속"
		)
		return nil
	end

	local fx = createPooledVfxFromTemplate(templateName, template)
	if not fx then
		return nil
	end

	pivotVfxRoot(fx, cf)
	fx.Parent = Workspace
	return fx
end

local function acquireVfxRoot(templateName: string, cf: CFrame, usePool: boolean): Instance?
	if usePool and VfxPool.isRegistered(templateName) then
		local template = effectTemplatesByName[templateName] or findEffectTemplate(templateName)
		if template then
			effectTemplatesByName[templateName] = template
			local pooled = VfxPool.acquire(templateName, template, cf)
			if pooled then
				return pooled
			end
		end
	end
	return cloneEffectTemplateToWorkspace(templateName, cf)
end

-- followPart: 주어지면 lifetime 동안 해당 파트의 GetPivot()을 따라감 (LevelUp 등)
-- onAcquire: 스케일 적용 후, Emit 예약 전에 root(clone)를 커스터마이즈할 콜백 (예: JudgementFx 텍스처 교체)
function VfxController.playAtCFrame(
	templateName: string,
	cf: CFrame,
	particleEmitCount: number,
	lifetime: number,
	modelScale: number?,
	followPart: BasePart?,
	usePool: boolean?,
	particleZOffset: number?,
	onAcquire: ((Instance) -> ())?
)
	if not templateName or templateName == "" then
		return
	end

	local s = modelScale
	if s == nil or s ~= s or s <= 0 then
		s = 1
	end

	local pooled = usePool == true and followPart == nil
	local root = acquireVfxRoot(templateName, cf, pooled)
	if not root then
		return
	end

	applyCharacterScaleToModels(root, s)

	if onAcquire then
		onAcquire(root)
	end

	scheduleEmitAndCleanup(root, particleEmitCount, lifetime, followPart, pooled, particleZOffset)
end

local function waitForRemoteEvent(name: string, timeoutSec: number): RemoteEvent?
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local got = ReplicatedStorage:WaitForChild(name, timeoutSec)
	if got and got:IsA("RemoteEvent") then
		return got
	end
	return nil
end

local function findJudgementParticleEmitter(model: Instance): ParticleEmitter?
	local c = GameSettings.Combat
	local particleName = c.JudgementFxParticleName or "judgement"
	local particle = model:FindFirstChild(particleName, true)
	if particle and particle:IsA("ParticleEmitter") then
		return particle
	end
	return nil
end

local function forEachJudgementParticle(root: Instance, fn: (ParticleEmitter) -> ())
	local function applyOne(model: Instance)
		local particle = findJudgementParticleEmitter(model)
		if particle then
			fn(particle)
		end
	end

	if root:IsA("Model") then
		applyOne(root)
	elseif root:IsA("Folder") then
		for _, ch in root:GetChildren() do
			if ch:IsA("Model") then
				applyOne(ch)
			end
		end
	end
end

--- JudgementFx의 "judgement" ParticleEmitter 텍스처를 대상 건물 레벨 비교 결과("Equal"/"Higher")에 맞게 교체.
local function applyJudgementFxTexture(root: Instance, kind: string?)
	local c = GameSettings.Combat
	local textureId = kind == "Equal" and c.JudgementFxTextureEqualLevelId or c.JudgementFxTextureHigherLevelId
	if typeof(textureId) ~= "string" or textureId == "" then
		return
	end
	forEachJudgementParticle(root, function(particle)
		particle.Texture = textureId
	end)
end

local function findLevelUpTextEffectParticle(model: Instance): ParticleEmitter?
	local c = GameSettings.Combat
	local particleName = c.LevelUpTextEffectParticleName or "TextEffect"
	local particle = model:FindFirstChild(particleName, true)
	if particle and particle:IsA("ParticleEmitter") then
		return particle
	end
	return nil
end

local function forEachLevelUpTextEffectParticle(root: Instance, fn: (ParticleEmitter) -> ())
	local function applyOne(model: Instance)
		local particle = findLevelUpTextEffectParticle(model)
		if particle then
			fn(particle)
		end
	end

	if root:IsA("Model") then
		applyOne(root)
	elseif root:IsA("Folder") then
		for _, ch in root:GetChildren() do
			if ch:IsA("Model") then
				applyOne(ch)
			end
		end
	end
end

--- LevelUp의 "TextEffect" ParticleEmitter ZOffset을 해당 레벨업 스케일(newScale)보다 margin만큼 높게 설정.
local function applyLevelUpTextEffectZOffset(root: Instance, scale: number?)
	if typeof(scale) ~= "number" or scale ~= scale then
		return
	end
	local c = GameSettings.Combat
	local margin = c.LevelUpTextEffectZOffsetScaleMargin
	if typeof(margin) ~= "number" then
		margin = 5
	end
	local zOffset = scale + margin
	forEachLevelUpTextEffectParticle(root, function(particle)
		particle.ZOffset = zOffset
	end)
end

local function registerCombatVfxPool(templateName: string, poolSize: number)
	if not templateName or templateName == "" then
		return
	end
	local template = findEffectTemplate(templateName)
	if not template then
		warn("[VfxController] VFX 풀 등록 실패 — 템플릿 없음:", templateName)
		return
	end
	effectTemplatesByName[templateName] = template
	VfxPool.register(templateName, template, poolSize)
end

function VfxController.init()
	local c = GameSettings.Combat
	local remoteWaitSec = 15

	VfxPool.init(createPooledVfxFromTemplate)
	registerCombatVfxPool(c.ExplodeEffectName or "ElectricBurst", c.ExplodeVfxPoolSize or 32)
	registerCombatVfxPool(c.HitFxName or "HitFx", c.HitVfxPoolSize or 24)
	registerCombatVfxPool(c.JudgementFxName or "JudgementFx", c.JudgementVfxPoolSize or 24)

	local explodeEv = waitForRemoteEvent("ExplodeVfxEvent", remoteWaitSec)
	if explodeEv then
		explodeEv.OnClientEvent:Connect(function(
			worldPosition: Vector3,
			modelScale: number?,
			playDestroySfx: boolean?,
			targetModel: Model?
		)
			if typeof(worldPosition) ~= "Vector3" then
				return
			end
			local s = modelScale
			if typeof(s) ~= "number" or s ~= s or s <= 0 then
				s = 1
			end

			local target: Model? = nil
			if typeof(targetModel) == "Instance" and targetModel:IsA("Model") and targetModel.Parent then
				target = targetModel
			end

			local visibleCf = HitFxVisibility.resolve(CFrame.new(worldPosition), target, s)

			VfxController.playAtCFrame(
				c.ExplodeEffectName,
				visibleCf,
				c.ExplodeParticleEmitCount or 25,
				c.ExplodeEffectLifetime or 3,
				s,
				nil,
				true
			)
			if playDestroySfx == true then
				SoundManager.playSfx(SoundManager.Sfx.Destroy)
			end
		end)
	else
		warn("[VfxController] ExplodeVfxEvent not found")
	end

	local hitFxEv = waitForRemoteEvent("HitFxEvent", remoteWaitSec)
	if hitFxEv then
		hitFxEv.OnClientEvent:Connect(function(
			hitFxCf: CFrame,
			scale: number,
			hitKind: string?,
			targetModel: Model?,
			attackerLevel: number?,
			maxHeadY: number?
		)
			if typeof(hitFxCf) ~= "CFrame" or typeof(scale) ~= "number" then
				return
			end
			scale = math.clamp(scale, HITFX_MIN_SCALE, GameSettings.Scale.MaxScale)

			local target: Model? = nil
			if typeof(targetModel) == "Instance" and targetModel:IsA("Model") and targetModel.Parent then
				target = targetModel
			end

			local kind = typeof(hitKind) == "string" and hitKind or SoundManager.HitFxKind.Attack
			local visibleCf: CFrame
			if kind == SoundManager.HitFxKind.Trample then
				visibleCf = HitFxVisibility.resolveTrample(hitFxCf, target, scale)
			elseif kind == SoundManager.HitFxKind.Attack then
				visibleCf = HitFxVisibility.resolveAttack(hitFxCf, target, scale, maxHeadY)
			else
				visibleCf = HitFxVisibility.resolve(hitFxCf, target, scale)
			end
			visibleCf = billboardTowardCamera(visibleCf.Position)
			local particleZOffset = computeHitFxZOffset(attackerLevel)

			VfxController.playAtCFrame(
				c.HitFxName,
				visibleCf,
				c.HitFxParticleEmitCount or 20,
				c.HitFxLifetime or 1,
				scale,
				nil,
				true,
				particleZOffset
			)

			if kind == SoundManager.HitFxKind.Trample then
				SoundManager.playSfx(SoundManager.Sfx.Trample)
			elseif kind ~= SoundManager.HitFxKind.Destroy then
				SoundManager.playSfx(SoundManager.Sfx.Hit)
			end
		end)
	else
		warn("[VfxController] HitFxEvent not found — punch hit VFX will not play")
	end

	local judgementFxEv = waitForRemoteEvent("JudgementFxEvent", remoteWaitSec)
	if judgementFxEv then
		judgementFxEv.OnClientEvent:Connect(function(
			hitFxCf: CFrame,
			scale: number,
			targetModel: Model?,
			kind: string?,
			maxHeadY: number?
		)
			if typeof(hitFxCf) ~= "CFrame" or typeof(scale) ~= "number" then
				return
			end
			scale = math.clamp(scale, HITFX_MIN_SCALE, GameSettings.Scale.MaxScale)

			local target: Model? = nil
			if typeof(targetModel) == "Instance" and targetModel:IsA("Model") and targetModel.Parent then
				target = targetModel
			end

			local visibleCf = HitFxVisibility.resolveAttack(hitFxCf, target, scale, maxHeadY)
			visibleCf = billboardTowardCamera(visibleCf.Position)

			VfxController.playAtCFrame(
				c.JudgementFxName,
				visibleCf,
				c.JudgementFxParticleEmitCount or 1,
				c.JudgementFxLifetime or 1,
				scale,
				nil,
				true,
				nil,
				function(root)
					applyJudgementFxTexture(root, kind)
				end
			)
		end)
	else
		warn("[VfxController] JudgementFxEvent not found — judgement VFX will not play")
	end

	-- 접속 직후 서버가 보내는 ScaleUpdateEvent를 VfxController가 놓치면(리스너 연결 전) 첫 증가 시 prev가 nil이 되어 이펙트가 안 나감.
	-- 서버 기본 스케일과 맞춰 두면 첫 +/- 버튼에서도 비교 가능.
	local lastScaleFromServer = GameSettings.Scale.PlayerScale
	local scaleUpdateEv = waitForRemoteEvent("ScaleUpdateEvent", remoteWaitSec)
	if scaleUpdateEv then
		scaleUpdateEv.OnClientEvent:Connect(function(newScale: number)
			if typeof(newScale) ~= "number" or newScale ~= newScale then
				return
			end
			newScale = math.clamp(newScale, GameSettings.Scale.MinScale, GameSettings.Scale.MaxScale)

			local prev = lastScaleFromServer
			lastScaleFromServer = newScale
			if newScale <= prev then
				return
			end
		end)
	end

	local levelUpVfxEv = waitForRemoteEvent("LevelUpVfxEvent", remoteWaitSec)
	if levelUpVfxEv then
		levelUpVfxEv.OnClientEvent:Connect(function(targetPlayer: Player, newScale: number)
			if typeof(newScale) ~= "number" or newScale ~= newScale then
				return
			end
			if typeof(targetPlayer) ~= "Instance" or not targetPlayer:IsA("Player") then
				return
			end

			local cfg = GameSettings.Combat
			local effectName = cfg.LevelUpEffectName or "LevelUp"
			if effectName == "" then
				return
			end

			newScale = math.clamp(newScale, GameSettings.Scale.MinScale, GameSettings.Scale.MaxScale)
			local character = targetPlayer.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			if not hrp or not hrp:IsA("BasePart") then
				return
			end

			VfxController.playAtCFrame(
				effectName,
				hrp:GetPivot(),
				cfg.LevelUpParticleEmitCount or 10,
				cfg.LevelUpLifetime or 1,
				newScale,
				hrp,
				false,
				nil,
				function(root)
					applyLevelUpTextEffectZOffset(root, newScale)
				end
			)

			if targetPlayer == Players.LocalPlayer then
				SoundManager.playSfx(SoundManager.Sfx.LevelUp)
			end
		end)
	end
end

return VfxController
