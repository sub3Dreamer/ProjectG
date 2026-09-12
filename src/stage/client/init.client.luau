local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local JumpControl = require(Shared.Utils.JumpControl)
local CharacterStability = require(Shared.Utils.CharacterStability)
local LocomotionAnimPreload = require(Shared.Utils.LocomotionAnimPreload)
local CameraZoomModule = require(Shared.Utils.CameraZoomModule)
local PopupManager = require(Shared.Managers.PopupManager)
local SoundManager = require(Shared.Managers.SoundManager)

local StageHUD = require(script.StageHUD)
local BossIntroCamera = require(script.BossIntroCamera)
local BossIntroPopup = require(script.popup.BossIntroPopup)
local StageBossLocator = require(script.StageBossLocator)
local StageStartBossFacing = require(script.StageStartBossFacing)
local CombatController = require(script.CombatController)
local VfxController = require(script.VfxController)
local GiantWalkSfx = require(script.GiantWalkSfx)
local HeadXpBar = require(script.HeadXpBar)
local ObjectHpBar = require(script.ObjectHpBar)
local ItemInventoryHUD = require(script.ItemInventoryHUD)
local PetRenderSmoothing = require(script.PetRenderSmoothing)
local ToastHUD = require(script.ToastHUD)
local SpeechBubbleWobble = require(script.SpeechBubbleWobble)
local PetTimerHud = require(script.PetTimerHud)

print("[Stage Client] 스테이지 클라이언트 시작")

local function onCharacter(character: Model)
	JumpControl.applyToCharacter(character)
	CharacterStability.apply(character)
end

local function hideTouchJumpButton()
	local player = Players.LocalPlayer
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end

	local function tryHide(inst: Instance)
		if inst:IsA("GuiButton") and inst.Name == "JumpButton" then
			inst.Visible = false
		end
	end

	for _, d in playerGui:GetDescendants() do
		tryHide(d)
	end
	playerGui.DescendantAdded:Connect(tryHide)
end

local player = Players.LocalPlayer
player.CharacterAdded:Connect(onCharacter)
if player.Character then
	task.defer(onCharacter, player.Character)
end

local scaleUpdateEvent = ReplicatedStorage:WaitForChild("ScaleUpdateEvent")
scaleUpdateEvent.OnClientEvent:Connect(function(newScale: number)
	if typeof(newScale) ~= "number" or newScale ~= newScale or newScale <= 0 then
		return
	end
	CameraZoomModule.setFixedZoom(player, newScale)
end)

hideTouchJumpButton()

-- PlayerGui.PopupScreenGui는 StarterGui 복제로 채워지는데, 이 LocalScript(StarterPlayerScripts)
-- 시작과 그 복제 완료 사이에 순서 보장이 없다. 동기 호출로 두면 WaitForChild가 오래 걸릴 때
-- SoundManager/LocomotionAnimPreload/StageHUD 등 이후 초기화 전체가 덩달아 지연되므로 분리한다.
task.spawn(PopupManager.init)
SoundManager.init()
LocomotionAnimPreload.init()
BossIntroCamera.beginPreload()
StageHUD.init()
HeadXpBar.init()
ObjectHpBar.init()
ItemInventoryHUD.init()
CombatController.init()
VfxController.init()
GiantWalkSfx.init()
PetRenderSmoothing.init()
ToastHUD.init()
SpeechBubbleWobble.init()
PetTimerHud.init()

-- 스튜디오에서만: C 키 → 스테이지 클리어, V 키 → GameOverPopup, Z 키 → BossIntroCamera, P 키 → 랜덤 펫 토스트,
-- O 키 → Area 기능 기준 랜덤 UFO 3개 스폰 (테스트)
if RunService:IsStudio() then
	local stageClearTest = ReplicatedStorage:WaitForChild("StageClearTestRequestEvent")
	local debugSpawnUfoTrioRequest = ReplicatedStorage:WaitForChild("DebugSpawnUfoTrioRequestEvent")
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.C then
			print("[StageClient] C 키 → stageClearTest:FireServer()")
			stageClearTest:FireServer()
		elseif input.KeyCode == Enum.KeyCode.V then
			print("[StageClient] V 키 → testTriggerGameOver()")
			StageHUD.testTriggerGameOver()
		elseif input.KeyCode == Enum.KeyCode.Z then
			print("[StageClient] Z 키 → StageStartBossFacing + BossIntroCamera.play()")
			StageHUD.setGameplayInputLocked(true)
			if BossIntroCamera.Enabled then
				local boss = StageBossLocator.waitForBoss()
				if boss then
					BossIntroPopup.begin(boss)
				end
			end
			StageStartBossFacing.apply()
			BossIntroCamera.play(function()
				StageHUD.setGameplayInputLocked(false)
			end)
		elseif input.KeyCode == Enum.KeyCode.P then
			print("[StageClient] P 키 → ToastHUD.testEnqueueRandomPet()")
			ToastHUD.testEnqueueRandomPet()
		elseif input.KeyCode == Enum.KeyCode.X then
			print("[StageClient] X 키 → debugSpawnUfoTrioRequest:FireServer()")
			debugSpawnUfoTrioRequest:FireServer()
		end
	end)
end

print("[Stage Client] 스테이지 클라이언트 초기화 완료")
