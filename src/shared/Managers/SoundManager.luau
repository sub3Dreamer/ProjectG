--[[
	클라이언트 전용: 음악/SFX 뮤트·볼륨 제어, BGM 재생, 볼륨 바 UI 동기화.
	토글(ON/OFF) 시각 상태는 SettingPopup 에서 처리.
	BGM 소스: ReplicatedStorage.Audio
	서버에서 require 시 no-op.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local SoundManager = {}

SoundManager.BgmMode = {
	Lobby = "Lobby",
	Stage = "Stage",
}

SoundManager.Sfx = {
	Countdown = "Mario Kart Race Start - Sound Effect (HD)",
	StageClear = "Old victory sound roblox",
	StageFail = "Sound Fail (Fallo)",
	Hit = "Punch",
	Destroy = "Ground Slam Impact Shockwave",
	Trample = "Sound Punch",
	GiantWalk = "Sound Punch",
	LevelUp = "Power_Up",
	Swing = "swing3",
	Rewards = "Rewards",
	RewardReveal = "reward_screen_reveal",
	Buy = "buy",
	Fever = "Explosion 2",
}

SoundManager.HitFxKind = {
	Attack = "attack",
	Trample = "trample",
	Destroy = "destroy",
}

if RunService:IsServer() then
	function SoundManager.init()
		warn("[SoundManager] init() called on SERVER (no-op)")
	end

	function SoundManager.startBgm(_mode: string)
		warn("[SoundManager] startBgm() called on SERVER (no-op)")
	end

	function SoundManager.stopBgm()
		warn("[SoundManager] stopBgm() called on SERVER (no-op)")
	end

	function SoundManager.playSfx(trackName: string, _parent: Instance?)
		warn(string.format(
			"[SoundManager] playSfx('%s') called on SERVER. This module is client-only.",
			tostring(trackName)
		))
	end

	return SoundManager
end

-- --- client ---

local PlaceManager = require(script.Parent.PlaceManager)

local VOL_COLOR_ACTIVE = Color3.fromRGB(85, 255, 0)
local VOL_COLOR_INACTIVE = Color3.fromRGB(74, 74, 74)
local VOLUME_LEVELS = { 0.04, 0.10, 0.19, 0.30, 0.42, 0.54, 0.68, 0.84, 1.0 }
local VOLUME_EPSILON = 1e-4

local musicGroup: SoundGroup? = nil
local sfxGroup: SoundGroup? = nil
local savedMusicVolume = 1
local savedSFXVolume = 1
local musicMuted = false
local sfxMuted = false

local initialized = false
local groupsHooked = false
local musicVolumeListeners: { () -> () } = {}
local sfxVolumeListeners: { () -> () } = {}

local AUDIO_FOLDER_NAME = "Audio"
local BGM_PLAYER_NAME = "BgmPlayer"
local LOBBY_BGM_TRACK = "Sunshine state of mind"
local STAGE_BGM_TRACKS = { "Action", "Sunshine state of mind", "Crab Rave Party" }
local STAGE_FIXED_BGM_BY_STAGE: { [number]: string } = {
	[1] = "Crab Rave Party",
}

local bgmSound: Sound? = nil
local bgmBaseVolume = 1
local bgmMode: string? = nil
local pendingBgmMode: string? = nil
local bgmEndedConnection: RBXScriptConnection? = nil

local function isEffectivelyMuted(volume: number): boolean
	return volume <= VOLUME_EPSILON
end

local function resolveSoundGroupsFromSoundService(): (SoundGroup?, SoundGroup?)
	local essentials = SoundService:FindFirstChild("RBLXEssentials")
	if not essentials then
		return nil, nil
	end
	local soundSystem = essentials:FindFirstChild("SoundSystem")
	if not soundSystem then
		return nil, nil
	end
	local music = soundSystem:FindFirstChild("Music")
	local sfx = soundSystem:FindFirstChild("SFX")
	if music and music:IsA("SoundGroup") and sfx and sfx:IsA("SoundGroup") then
		return music, sfx
	end
	return nil, nil
end

local function ensureSoundGroups(): boolean
	local music, sfx = resolveSoundGroupsFromSoundService()
	if not music or not sfx then
		return false
	end

	local groupsChanged = musicGroup ~= music or sfxGroup ~= sfx
	musicGroup = music
	sfxGroup = sfx

	if groupsChanged or not groupsHooked then
		if music.Volume > VOLUME_EPSILON then
			savedMusicVolume = music.Volume
		end
		if sfx.Volume > VOLUME_EPSILON then
			savedSFXVolume = sfx.Volume
		end
		musicMuted = isEffectivelyMuted(music.Volume)
		sfxMuted = isEffectivelyMuted(sfx.Volume)
	end

	return true
end

local function notifyMusicVolumeListeners()
	for _, cb in ipairs(musicVolumeListeners) do
		cb()
	end
end

local function notifySfxVolumeListeners()
	for _, cb in ipairs(sfxVolumeListeners) do
		cb()
	end
end

function SoundManager.onMusicVolumeChanged(callback: () -> ()): () -> ()
	table.insert(musicVolumeListeners, callback)
	return function()
		local idx = table.find(musicVolumeListeners, callback)
		if idx then
			table.remove(musicVolumeListeners, idx)
		end
	end
end

function SoundManager.onSfxVolumeChanged(callback: () -> ()): () -> ()
	table.insert(sfxVolumeListeners, callback)
	return function()
		local idx = table.find(sfxVolumeListeners, callback)
		if idx then
			table.remove(sfxVolumeListeners, idx)
		end
	end
end

function SoundManager.isMusicMuted(): boolean
	ensureSoundGroups()
	return musicMuted
end

function SoundManager.isSfxMuted(): boolean
	ensureSoundGroups()
	return sfxMuted
end

function SoundManager.getMusicVolume(): number
	if not ensureSoundGroups() or not musicGroup then
		return 1
	end
	return musicGroup.Volume
end

local function volumeToStep(volume: number): number
	if volume <= VOLUME_EPSILON then
		return 0
	end
	local nearest, nearestDist = 1, math.huge
	for i, v in ipairs(VOLUME_LEVELS) do
		local dist = math.abs(v - volume)
		if dist < nearestDist then
			nearest, nearestDist = i, dist
		end
	end
	return nearest
end

local function updateVolumeBar(volumeFrame: Instance?, volume: number)
	if not volumeFrame then
		return
	end
	local lit = volumeToStep(volume)
	for i = 1, #VOLUME_LEVELS do
		local frame = volumeFrame:FindFirstChild("Volume" .. i)
		if frame and frame:IsA("GuiObject") then
			frame.BackgroundColor3 = i <= lit and VOL_COLOR_ACTIVE or VOL_COLOR_INACTIVE
			frame.BackgroundTransparency = i <= lit and 0 or 0.5
		end
	end
end

local function findVolumeFrame(groupName: string): Instance?
	local playerGui = Players.LocalPlayer.PlayerGui
	for _, d in ipairs(playerGui:GetDescendants()) do
		if d:GetAttribute("VolumeGroup") == groupName then
			return d:FindFirstChild("VolumeFrame")
		end
	end
	return nil
end

local function getEffectiveMusicVolumeMultiplier(): number
	if not musicGroup then
		return 1
	end
	if musicMuted or musicGroup.Volume <= VOLUME_EPSILON then
		return 0
	end
	return musicGroup.Volume
end

local function getEffectiveSfxVolumeMultiplier(): number
	if not sfxGroup then
		return 1
	end
	if sfxMuted or sfxGroup.Volume <= VOLUME_EPSILON then
		return 0
	end
	return sfxGroup.Volume
end

local function syncBgmVolume()
	if not bgmSound then
		return
	end
	bgmSound.Volume = bgmBaseVolume * getEffectiveMusicVolumeMultiplier()
end

local function syncMusicVolumeUI()
	if not musicGroup then
		return
	end
	updateVolumeBar(findVolumeFrame("Music"), musicGroup.Volume)
end

local function onMusicOutputChanged()
	syncBgmVolume()
	syncMusicVolumeUI()
	notifyMusicVolumeListeners()
end

local function syncSfxVolumeUI()
	if not sfxGroup then
		return
	end
	updateVolumeBar(findVolumeFrame("SFX"), sfxGroup.Volume)
end

local function resolveVolumeFrame(groupName: string, volumeFrame: Instance?): Instance?
	return volumeFrame or findVolumeFrame(groupName)
end

local function getMusicRestoreVolume(): number
	local restore = savedMusicVolume
	if restore <= VOLUME_EPSILON then
		restore = 1
	end
	return restore
end

local function getSfxRestoreVolume(): number
	local restore = savedSFXVolume
	if restore <= VOLUME_EPSILON then
		restore = 1
	end
	return restore
end

local function restoreMusicVolumeIfNeeded()
	if not musicGroup or musicMuted then
		return
	end
	if musicGroup.Volume <= VOLUME_EPSILON then
		musicGroup.Volume = getMusicRestoreVolume()
	end
end

local function restoreSfxVolumeIfNeeded()
	if not sfxGroup or sfxMuted then
		return
	end
	if sfxGroup.Volume <= VOLUME_EPSILON then
		sfxGroup.Volume = getSfxRestoreVolume()
	end
end

local function applyMusicVolumeToGroup()
	if not musicGroup then
		return
	end
	if musicMuted then
		if musicGroup.Volume > VOLUME_EPSILON then
			savedMusicVolume = musicGroup.Volume
		end
		musicGroup.Volume = 0
	else
		musicGroup.Volume = getMusicRestoreVolume()
	end
end

local function applySfxVolumeToGroup()
	if not sfxGroup then
		return
	end
	if sfxMuted then
		if sfxGroup.Volume > VOLUME_EPSILON then
			savedSFXVolume = sfxGroup.Volume
		end
		sfxGroup.Volume = 0
	else
		sfxGroup.Volume = getSfxRestoreVolume()
	end
end

local function enforceMusicMuteIfNeeded()
	if not musicGroup or not musicMuted then
		return
	end
	if musicGroup.Volume > VOLUME_EPSILON then
		musicGroup.Volume = 0
	end
end

local function enforceSfxMuteIfNeeded()
	if not sfxGroup or not sfxMuted then
		return
	end
	if sfxGroup.Volume > VOLUME_EPSILON then
		sfxGroup.Volume = 0
	end
end

local function adjustVolume(group: SoundGroup, groupName: string, direction: number, volumeFrame: Instance?, mutedFlag: { value: boolean })
	local step = volumeToStep(group.Volume)
	local newStep = math.max(0, math.min(#VOLUME_LEVELS, step + direction))
	local newVol = newStep > 0 and VOLUME_LEVELS[newStep] or 0
	group.Volume = newVol
	if group.Volume <= VOLUME_EPSILON then
		group.Volume = 0
		mutedFlag.value = true
	else
		mutedFlag.value = false
		if groupName == "Music" then
			savedMusicVolume = group.Volume
		else
			savedSFXVolume = group.Volume
		end
	end
	updateVolumeBar(resolveVolumeFrame(groupName, volumeFrame), group.Volume)
	if groupName == "Music" then
		syncBgmVolume()
	end
end

function SoundManager.applyMusicVolumeUI(volumeFrame: Instance?)
	if not ensureSoundGroups() or not musicGroup then
		return
	end
	updateVolumeBar(resolveVolumeFrame("Music", volumeFrame), musicGroup.Volume)
end

function SoundManager.applySfxVolumeUI(volumeFrame: Instance?)
	if not ensureSoundGroups() or not sfxGroup then
		return
	end
	updateVolumeBar(resolveVolumeFrame("SFX", volumeFrame), sfxGroup.Volume)
end

function SoundManager.toggleMusicMute()
	if not ensureSoundGroups() or not musicGroup then
		warn("[SoundManager] Music SoundGroup 없음 (SoundService.RBLXEssentials.SoundSystem.Music)")
		return
	end

	local before = musicGroup.Volume
	musicMuted = not musicMuted
	applyMusicVolumeToGroup()
	if musicMuted then
		enforceMusicMuteIfNeeded()
	else
		restoreMusicVolumeIfNeeded()
		task.defer(restoreMusicVolumeIfNeeded)
	end
	syncBgmVolume()

	print(
		"[SoundManager] toggleMusicMute muted=",
		musicMuted,
		"volume",
		before,
		"->",
		musicGroup.Volume,
		"path=",
		musicGroup:GetFullName()
	)
end

function SoundManager.toggleSFXMute()
	if not ensureSoundGroups() or not sfxGroup then
		warn("[SoundManager] SFX SoundGroup 없음 (SoundService.RBLXEssentials.SoundSystem.SFX)")
		return
	end

	sfxMuted = not sfxMuted
	applySfxVolumeToGroup()
	if sfxMuted then
		enforceSfxMuteIfNeeded()
	else
		restoreSfxVolumeIfNeeded()
		task.defer(restoreSfxVolumeIfNeeded)
	end
end

function SoundManager.musicVolumeUp(volumeFrame: Instance?)
	if not ensureSoundGroups() or not musicGroup then
		return
	end
	local flag = { value = musicMuted }
	adjustVolume(musicGroup, "Music", 1, volumeFrame, flag)
	musicMuted = flag.value
end

function SoundManager.musicVolumeDown(volumeFrame: Instance?)
	if not ensureSoundGroups() or not musicGroup then
		return
	end
	local flag = { value = musicMuted }
	adjustVolume(musicGroup, "Music", -1, volumeFrame, flag)
	musicMuted = flag.value
end

function SoundManager.sfxVolumeUp(volumeFrame: Instance?)
	if not ensureSoundGroups() or not sfxGroup then
		return
	end
	local flag = { value = sfxMuted }
	adjustVolume(sfxGroup, "SFX", 1, volumeFrame, flag)
	sfxMuted = flag.value
end

function SoundManager.sfxVolumeDown(volumeFrame: Instance?)
	if not ensureSoundGroups() or not sfxGroup then
		return
	end
	local flag = { value = sfxMuted }
	adjustVolume(sfxGroup, "SFX", -1, volumeFrame, flag)
	sfxMuted = flag.value
end

local function bindGroupListeners()
	if not musicGroup or not sfxGroup then
		return
	end

	musicGroup:GetPropertyChangedSignal("Volume"):Connect(function()
		if musicMuted then
			if musicGroup and musicGroup.Volume > VOLUME_EPSILON then
				task.defer(enforceMusicMuteIfNeeded)
			end
		elseif musicGroup and musicGroup.Volume > VOLUME_EPSILON then
			savedMusicVolume = musicGroup.Volume
		end
		onMusicOutputChanged()
	end)

	sfxGroup:GetPropertyChangedSignal("Volume"):Connect(function()
		if sfxMuted then
			if sfxGroup and sfxGroup.Volume > VOLUME_EPSILON then
				task.defer(enforceSfxMuteIfNeeded)
			end
		elseif sfxGroup and sfxGroup.Volume > VOLUME_EPSILON then
			savedSFXVolume = sfxGroup.Volume
		end
		syncSfxVolumeUI()
		notifySfxVolumeListeners()
	end)
end

local function getAudioFolder(): Folder?
	local folderInst = ReplicatedStorage:FindFirstChild(AUDIO_FOLDER_NAME)
	if folderInst and folderInst:IsA("Folder") then
		return folderInst
	end
	return nil
end

local function getAudioTemplate(trackName: string): Sound?
	local folder = getAudioFolder()
	if not folder then
		warn("[SoundManager] ReplicatedStorage.Audio 없음")
		return nil
	end
	local soundInst = folder:FindFirstChild(trackName)
	if soundInst and soundInst:IsA("Sound") then
		return soundInst
	end
	warn("[SoundManager] Audio 트랙 없음:", trackName)
	return nil
end

function SoundManager.playSfx(trackName: string, parent: Instance?)

	print("[SoundManager] playSfx : ", trackName)

	ensureSoundGroups()

	local template = getAudioTemplate(trackName)
	if not template then
		return
	end
	
	local sound = template:Clone()
	local baseVolume = sound.Volume
	sound.Volume = baseVolume * getEffectiveSfxVolumeMultiplier()
	sound.Parent = parent or SoundService
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	sound:Play()
end

local function detachBgmEndedListener()
	if bgmEndedConnection then
		bgmEndedConnection:Disconnect()
		bgmEndedConnection = nil
	end
end

local function destroyBgmSound()
	detachBgmEndedListener()
	if bgmSound then
		bgmSound:Stop()
		bgmSound:Destroy()
		bgmSound = nil
	end
end

local function getFixedStageBgmTrack(stageNumber: number?): string?
	if typeof(stageNumber) ~= "number" then
		return nil
	end
	return STAGE_FIXED_BGM_BY_STAGE[stageNumber]
end

local function pickRandomStageTrack(): string
	return STAGE_BGM_TRACKS[math.random(1, #STAGE_BGM_TRACKS)]
end

local function playBgmTrack(trackName: string, loopSingleTrack: boolean)
	local template = getAudioTemplate(trackName)
	if not template then
		return
	end

	destroyBgmSound()

	local sound = template:Clone()
	sound.Name = BGM_PLAYER_NAME
	sound.Looped = loopSingleTrack
	bgmBaseVolume = sound.Volume
	sound.Parent = SoundService
	bgmSound = sound
	syncBgmVolume()
	sound:Play()

	if not loopSingleTrack then
		bgmEndedConnection = sound.Ended:Connect(function()
			if bgmMode ~= SoundManager.BgmMode.Stage then
				return
			end
			playBgmTrack(pickRandomStageTrack(), false)
		end)
	end

	print(string.format("[SoundManager] BGM 재생: %s (loop=%s)", trackName, tostring(loopSingleTrack)))
end

local function startBgmInternal(mode: string)
	if mode == SoundManager.BgmMode.Lobby then
		bgmMode = mode
		playBgmTrack(LOBBY_BGM_TRACK, true)
		return
	end

	if mode == SoundManager.BgmMode.Stage then
		bgmMode = mode
		local _, stageNumber = PlaceManager.getCurrentPlaceType()
		local fixedTrack = getFixedStageBgmTrack(stageNumber)
		if fixedTrack then
			playBgmTrack(fixedTrack, true)
		else
			playBgmTrack(pickRandomStageTrack(), false)
		end
		return
	end

	warn("[SoundManager] 알 수 없는 BGM mode:", mode)
end

function SoundManager.stopBgm()
	pendingBgmMode = nil
	bgmMode = nil
	destroyBgmSound()
end

function SoundManager.startBgm(mode: string)
	pendingBgmMode = mode
	if not ensureSoundGroups() then
		return
	end
	pendingBgmMode = nil
	startBgmInternal(mode)
end

function SoundManager.init()
	if initialized then
		return
	end
	initialized = true

	task.spawn(function()
		local essentials = SoundService:WaitForChild("RBLXEssentials", 60)
		local soundSystem = essentials:WaitForChild("SoundSystem", 60)
		soundSystem:WaitForChild("Music", 60)
		soundSystem:WaitForChild("SFX", 60)

		if not ensureSoundGroups() then
			warn("[SoundManager] SoundService 에 Music/SFX SoundGroup 를 찾지 못했습니다")
			return
		end

		if not groupsHooked then
			groupsHooked = true
			bindGroupListeners()
		end
		syncBgmVolume()
		syncMusicVolumeUI()
		syncSfxVolumeUI()

		if pendingBgmMode then
			local mode = pendingBgmMode
			pendingBgmMode = nil
			startBgmInternal(mode)
		end
	end)
end

return SoundManager
