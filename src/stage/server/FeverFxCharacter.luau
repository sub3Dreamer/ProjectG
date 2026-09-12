--[[
	서버: 스테이지 진입 시 FeverFx 템플릿 안 HumanoidRootPart의 Attachment(복수 가능)를
	플레이어 HumanoidRootPart로 옮긴 뒤 파티클은 끔.
	Fever 버튼으로 파티클 ON/OFF + 캐릭터 Attribute FeverMode 및 이동속도(레벨 기준 × FeverMode).
	스케일 변경 시 Size/Speed 반영.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameSettings = require(Shared.Config.GameSettings)
local GameManager = require(Shared.Managers.GameManager)
local MissionHelper = require(Shared.Helpers.MissionHelper)
local AchievementHelper = require(Shared.Helpers.AchievementHelper)
local ScaleModule = require(Shared.Utils.ScaleModule)
local FeverGaugeHandler = require(script.Parent.FeverGaugeHandler)
local FeverFxCharacter = {}

-- 파티클 켜짐(버튼 토글). 기본 false
local feverParticlesEnabled: { [number]: boolean } = {}
-- 자동 피버 종료 타이머 무효화용(수동 OFF 또는 새 ON 시 증가)
local feverAutoOffSeq: { [number]: number } = {}
-- 플레이어 HRP에 붙인 Fever용 Attachment 목록(여러 개)
local feverAnchorsByUserId = {} :: { [number]: { Attachment } }
-- 템플릿 기준(스케일 1) 스냅샷 — Attachment 자식 ParticleEmitter
local feverEmitterSnaps = {} :: { [number]: any }

local function getEffectsFolder(): Folder?
	local name = GameSettings.Combat.EffectsFolderName
	local folder = ReplicatedStorage:FindFirstChild(name)
	if folder and folder:IsA("Folder") then
		return folder
	end
	return nil
end

local function getTemplateRoot(): Instance?
	local effects = getEffectsFolder()
	if not effects then
		return nil
	end
	local n = GameSettings.Combat.FeverFxName
	local t = effects:FindFirstChild(n)
	return t
end

local function findInnerHumanoidRootPart(root: Instance): BasePart?
	if root:IsA("Model") then
		local p = root:FindFirstChild("HumanoidRootPart", true)
		if p and p:IsA("BasePart") then
			return p
		end
	elseif root:IsA("Folder") then
		for _, ch in root:GetChildren() do
			if ch:IsA("Model") then
				local p = ch:FindFirstChild("HumanoidRootPart", true)
				if p and p:IsA("BasePart") then
					return p
				end
			end
		end
	end
	return nil
end

local function getAttachmentsOnFeverHRP(hrp: BasePart): { Attachment }
	local list: { Attachment } = {}
	for _, ch in hrp:GetChildren() do
		if ch:IsA("Attachment") then
			table.insert(list, ch)
		end
	end
	return list
end

local function anchorsStillOnHRP(anchors: { Attachment }?, charHRP: BasePart?): boolean
	if not charHRP or not anchors or #anchors == 0 then
		return false
	end
	for _, a in anchors do
		if not a.Parent or a.Parent ~= charHRP then
			return false
		end
	end
	return true
end

local function scaleNumberSequence(seq: NumberSequence, mul: number): NumberSequence
	local k = seq.Keypoints
	local newK = table.create(#k)
	for i = 1, #k do
		local kp = k[i]
		newK[i] = NumberSequenceKeypoint.new(kp.Time, kp.Value * mul, kp.Envelope * mul)
	end
	return NumberSequence.new(newK)
end

local function snapshotEmittersUnder(attachment: Attachment): { { emitter: ParticleEmitter, size: NumberSequence, speed: NumberRange } }
	local list = {}
	for _, d in attachment:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			table.insert(list, {
				emitter = d,
				size = d.Size,
				speed = d.Speed,
			})
		end
	end
	return list
end

local function snapshotEmittersUnderAllAttachments(attachments: { Attachment }): { { emitter: ParticleEmitter, size: NumberSequence, speed: NumberRange } }
	local merged = {}
	for _, att in attachments do
		for _, row in snapshotEmittersUnder(att) do
			table.insert(merged, row)
		end
	end
	return merged
end

local function applyEmitterVisualScale(userId: number, worldScale: number)
	local snaps = feverEmitterSnaps[userId]
	if not snaps then
		return
	end
	local ref = GameSettings.Scale.PlayerScale
	local mul = worldScale / ref
	if mul ~= mul or mul <= 0 then
		mul = 1
	end
	for _, row in snaps do
		local pe = row.emitter
		if pe.Parent then
			pe.Size = scaleNumberSequence(row.size, mul)
			pe.Speed = NumberRange.new(row.speed.Min * mul, row.speed.Max * mul)
		end
	end
end

local function setEmittersEnabled(userId: number, enabled: boolean)
	local snaps = feverEmitterSnaps[userId]
	if not snaps then
		return
	end
	for _, row in snaps do
		local pe = row.emitter
		if pe.Parent and pe:IsA("ParticleEmitter") then
			pe.Enabled = enabled
		end
	end
end

local function syncFeverModeAttributeAndWalkSpeed(player: Player)
	local character = player.Character
	if not character then
		return
	end
	character:SetAttribute("FeverMode", feverParticlesEnabled[player.UserId] == true)
	ScaleModule.applyWalkSpeedForCharacter(character)
end

local function getFeverAnimationInputLockSeconds(): number
	local cfg = GameSettings.Combat.FeverAnimation
	if typeof(cfg) == "table" and typeof(cfg.InputLockSeconds) == "number" and cfg.InputLockSeconds > 0 then
		return cfg.InputLockSeconds
	end
	return 1
end

local function getFeverAnimationDurationSeconds(): number
	local cfg = GameSettings.Combat.FeverAnimation
	if typeof(cfg) == "table" and typeof(cfg.DurationSeconds) == "number" and cfg.DurationSeconds > 0 then
		return cfg.DurationSeconds
	end
	return 1
end

--- 피버 모드 기본 유지시간(초, 유물 FeverDurationUp 보너스 적용 전 기준값)
local function getFeverModeDurationSec(): number
	local cfg = GameSettings.Combat.FeverMode
	if typeof(cfg) == "table" and typeof(cfg.DurationSeconds) == "number" and cfg.DurationSeconds > 0 then
		return cfg.DurationSeconds
	end
	return 10
end

local function setFeverIntroLocked(player: Player, locked: boolean)
	local character = player.Character
	if not character then
		return
	end
	if locked then
		character:SetAttribute("FeverIntroLocked", true)
	else
		character:SetAttribute("FeverIntroLocked", nil)
	end
end

local function clearPlayerState(userId: number)
	feverParticlesEnabled[userId] = nil
	feverAnchorsByUserId[userId] = nil
	feverEmitterSnaps[userId] = nil
	feverAutoOffSeq[userId] = nil
end

local function destroyFeverAttachments(player: Player)
	local anchors = feverAnchorsByUserId[player.UserId]
	if anchors then
		for _, att in anchors do
			if att.Parent then
				att:Destroy()
			end
		end
	end
	clearPlayerState(player.UserId)
end

local function getScaleForPlayer(player: Player, playerScales: { [number]: number }): number
	local s = playerScales[player.UserId]
	if typeof(s) == "number" and s == s and s > 0 then
		return s
	end
	local ch = player.Character
	if ch then
		return ScaleModule.getCharacterScale(ch)
	end
	return GameSettings.Scale.PlayerScale
end

function FeverFxCharacter.setupForCharacter(player: Player, playerScales: { [number]: number })
	local character = player.Character
	if not character then
		return
	end

	local charHRP = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not charHRP then
		return
	end

	local existing = feverAnchorsByUserId[player.UserId]
	if anchorsStillOnHRP(existing, charHRP) then
		FeverFxCharacter.onPlayerScaled(player, getScaleForPlayer(player, playerScales), playerScales)
		return
	end

	if existing then
		destroyFeverAttachments(player)
	end

	local templateRoot = getTemplateRoot()
	if not templateRoot then
		warn("[FeverFxCharacter] 템플릿 없음: ReplicatedStorage.", GameSettings.Combat.EffectsFolderName, ".", GameSettings.Combat.FeverFxName)
		return
	end

	local innerHRP = findInnerHumanoidRootPart(templateRoot)
	if not innerHRP then
		warn("[FeverFxCharacter] FeverFx 안에 HumanoidRootPart(BasePart)가 없습니다.")
		return
	end

	local srcAttachments = getAttachmentsOnFeverHRP(innerHRP)
	if #srcAttachments == 0 then
		warn("[FeverFxCharacter] FeverFx의 HumanoidRootPart에 Attachment가 없습니다.")
		return
	end

	local rootAtt = charHRP:FindFirstChild("RootAttachment")
	if not rootAtt or not rootAtt:IsA("Attachment") then
		warn("[FeverFxCharacter] 캐릭터 HumanoidRootPart에 RootAttachment가 없습니다.")
		return
	end

	local cloneRoot = templateRoot:Clone()
	cloneRoot.Name = "FeverFxSetupTemp"
	cloneRoot.Parent = ReplicatedStorage

	local cloneInner = findInnerHumanoidRootPart(cloneRoot)
	if not cloneInner then
		cloneRoot:Destroy()
		warn("[FeverFxCharacter] 클론에서 HumanoidRootPart를 찾지 못했습니다.")
		return
	end

	local feverAttachments = getAttachmentsOnFeverHRP(cloneInner)
	if #feverAttachments == 0 then
		cloneRoot:Destroy()
		warn("[FeverFxCharacter] 클론 HumanoidRootPart에 Attachment가 없습니다.")
		return
	end

	local moved: { Attachment } = {}
	for i, feverAtt in ipairs(feverAttachments) do
		local relCFrame = feverAtt.CFrame
		feverAtt.Name = "FeverFxAttachment_" .. tostring(i)
		feverAtt.Parent = charHRP
		feverAtt.CFrame = rootAtt.CFrame * relCFrame
		table.insert(moved, feverAtt)
	end

	local uid = player.UserId
	feverEmitterSnaps[uid] = snapshotEmittersUnderAllAttachments(moved)

	cloneRoot:Destroy()
	feverAnchorsByUserId[uid] = moved
	feverParticlesEnabled[uid] = false

	applyEmitterVisualScale(uid, getScaleForPlayer(player, playerScales))
	setEmittersEnabled(uid, false)
	syncFeverModeAttributeAndWalkSpeed(player)
end

function FeverFxCharacter.onPlayerScaled(player: Player, newScale: number, playerScales: { [number]: number })
	local uid = player.UserId
	local anchors = feverAnchorsByUserId[uid]
	local character = player.Character
	local charHRP = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?

	if feverEmitterSnaps[uid] and not anchorsStillOnHRP(anchors, charHRP) then
		FeverFxCharacter.setupForCharacter(player, playerScales)
		return
	end

	if not anchorsStillOnHRP(anchors, charHRP) or not feverEmitterSnaps[uid] then
		return
	end

	local s = typeof(newScale) == "number" and newScale == newScale and newScale > 0 and newScale or getScaleForPlayer(player, playerScales)
	applyEmitterVisualScale(uid, s)
	setEmittersEnabled(uid, feverParticlesEnabled[uid] == true)
end

function FeverFxCharacter.toggle(player: Player, playerScales: { [number]: number })
	local uid = player.UserId
	if not feverAnchorsByUserId[uid] or not feverEmitterSnaps[uid] then
		FeverFxCharacter.setupForCharacter(player, playerScales)
	end

	if not feverAnchorsByUserId[uid] then
		return
	end

	local wasOn = feverParticlesEnabled[uid] == true

	if not wasOn then
		if FeverGaugeHandler.getGauge(player) < 0.999 then
			return
		end
		FeverGaugeHandler.resetAfterFeverActivation(player)
	else
		-- 수동 OFF: 예약된 자동 종료 취소
		feverAutoOffSeq[uid] = (feverAutoOffSeq[uid] or 0) + 1
		setFeverIntroLocked(player, false)
	end

	feverParticlesEnabled[uid] = not wasOn
	setEmittersEnabled(uid, feverParticlesEnabled[uid] == true)

	local s = getScaleForPlayer(player, playerScales)
	applyEmitterVisualScale(uid, s)

	local dur = getFeverModeDurationSec()
	if not wasOn then
		-- 유물 FeverDurationUp 옵션만큼 지속시간 연장
		local durationBonusSec = GameManager.getPlayerOptionTotal(player, "FeverDurationUp")
		if durationBonusSec > 0 then
			dur += durationBonusSec
		end
		-- 클라이언트 카운트다운 표시가 실제 지속시간(보너스 포함)을 알 수 있도록 Attribute로 동기화
		local character = player.Character
		if character then
			character:SetAttribute("FeverDurationSeconds", dur)
		end
	end

	syncFeverModeAttributeAndWalkSpeed(player)

	if not wasOn then
		MissionHelper.incrementProgress(player, 3)
		AchievementHelper.incrementByType(player, "Fever")

		local character = player.Character
		if character then
			setFeverIntroLocked(player, true)
			local inputLockSec = getFeverAnimationInputLockSeconds()
			task.delay(inputLockSec, function()
				if not player.Parent then
					return
				end
				if feverParticlesEnabled[uid] ~= true then
					return
				end
				setFeverIntroLocked(player, false)
			end)
		end

		-- 방금 ON → 애니 종료 후 DurationSeconds(+보너스) 동안 유지
		feverAutoOffSeq[uid] = (feverAutoOffSeq[uid] or 0) + 1
		local seq = feverAutoOffSeq[uid]
		local introDur = getFeverAnimationDurationSeconds()
		local function feverAutoOffAfterDuration()
			if not player.Parent then
				return
			end
			if feverAutoOffSeq[uid] ~= seq then
				return
			end
			if feverParticlesEnabled[uid] ~= true then
				return
			end
			feverParticlesEnabled[uid] = false
			setEmittersEnabled(uid, false)
			setFeverIntroLocked(player, false)
			local s2 = getScaleForPlayer(player, playerScales)
			applyEmitterVisualScale(uid, s2)
			syncFeverModeAttributeAndWalkSpeed(player)
		end
		task.delay(introDur + dur, feverAutoOffAfterDuration)
	end
end

function FeverFxCharacter.init(remoteEvent: RemoteEvent, playerScales: { [number]: number })
	remoteEvent.OnServerEvent:Connect(function(player: Player)
		FeverFxCharacter.toggle(player, playerScales)
	end)

	local function onCharacterAdded(player: Player)
		task.defer(function()
			task.wait(0.25)
			if not player.Parent then
				return
			end
			FeverFxCharacter.setupForCharacter(player, playerScales)
		end)
	end

	local function hookPlayer(player: Player)
		player.CharacterAdded:Connect(function()
			feverParticlesEnabled[player.UserId] = false
			onCharacterAdded(player)
		end)
	end

	for _, p in Players:GetPlayers() do
		hookPlayer(p)
	end
	Players.PlayerAdded:Connect(hookPlayer)

	Players.PlayerRemoving:Connect(function(player: Player)
		destroyFeverAttachments(player)
	end)

	for _, p in Players:GetPlayers() do
		if p.Character then
			task.spawn(function()
				task.wait(0.25)
				if p.Parent and p.Character then
					FeverFxCharacter.setupForCharacter(p, playerScales)
				end
			end)
		end
	end
end

return FeverFxCharacter
