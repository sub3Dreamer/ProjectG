--[[
	스테이지 시작 시 플레이어·카메라를 보스 방향으로 맞춤 (BossIntroCamera 줌 인트로와 별개).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CameraZoomModule = require(Shared.Utils.CameraZoomModule)
local StageBossLocator = require(script.Parent.StageBossLocator)

local StageStartBossFacing = {}

StageStartBossFacing.Enabled = true

local player = Players.LocalPlayer

local function getPlayerLookAtPosition(character: Model): Vector3?
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil
	end

	local ok, cf, size = pcall(function()
		return character:GetBoundingBox()
	end)
	local lookY = hrp.Position.Y
	if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
		lookY = cf.Position.Y + size.Y * 0.35
	end
	return Vector3.new(hrp.Position.X, lookY, hrp.Position.Z)
end

local function getPlayerCameraPosition(character: Model): Vector3?
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil
	end

	local lookAt = getPlayerLookAtPosition(character)
	if not lookAt then
		return nil
	end

	local scale = CameraZoomModule.getCharacterScale(character)
	local distance = CameraZoomModule.getFixedDistance(scale)

	local back = -hrp.CFrame.LookVector
	if back.Magnitude < 0.01 then
		back = Vector3.new(0, 0, 1)
	else
		back = back.Unit
	end
	return lookAt + back * distance + Vector3.new(0, distance * 0.15, 0)
end

local function getPlayerCameraCFrame(character: Model): CFrame?
	local camPos = getPlayerCameraPosition(character)
	local lookAt = getPlayerLookAtPosition(character)
	if not camPos or not lookAt then
		return nil
	end
	return CFrame.lookAt(camPos, lookAt)
end

local function faceCharacterTowardBoss(character: Model, boss: Model)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	local rootPos = hrp.Position
	local bossPos = StageBossLocator.getLookAtPosition(boss)
	local flatTarget = Vector3.new(bossPos.X, rootPos.Y, bossPos.Z)
	if (flatTarget - rootPos).Magnitude < 0.5 then
		return
	end

	character:PivotTo(CFrame.lookAt(rootPos, flatTarget))
end

--- 플레이어 뒤 위치 + 플레이어 가슴 lookAt (기본 3인칭 pitch). Scriptable 스냅 후 Custom 복구.
function StageStartBossFacing.snapCameraBehindPlayerFacingBoss(character: Model, _boss: Model): boolean
	local camera = Workspace.CurrentCamera
	if not camera then
		return false
	end

	local playerCf = getPlayerCameraCFrame(character)
	if not playerCf then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = playerCf
	camera.CameraType = Enum.CameraType.Custom
	if humanoid and humanoid.Parent then
		camera.CameraSubject = humanoid
	end

	return true
end

--- BossIntroCamera 등 Scriptable 인트로용: 플레이어 뒤 + 보스 lookAt CFrame.
function StageStartBossFacing.getFacingCameraCFrame(character: Model, boss: Model): CFrame?
	local camPos = getPlayerCameraPosition(character)
	if not camPos then
		return nil
	end
	return CFrame.lookAt(camPos, StageBossLocator.getLookAtPosition(boss))
end

--- 보스가 있으면 캐릭터·카메라를 보스 방향으로 맞춤. 성공 여부 반환.
function StageStartBossFacing.apply(): boolean
	if not StageStartBossFacing.Enabled then
		return false
	end

	local character = player.Character
	if not character then
		return false
	end

	local boss = StageBossLocator.waitForBoss()
	if not boss then
		return false
	end

	faceCharacterTowardBoss(character, boss)
	return StageStartBossFacing.snapCameraBehindPlayerFacingBoss(character, boss)
end

return StageStartBossFacing
