--[[
	StageMap 직계 자식 Model 중 StageBoss=true 보스 탐색·프레이밍 정보.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameSettings = require(Shared.Config.GameSettings)

local StageBossLocator = {}

local STAGE_MAP_NAME = "StageMap"
local STAGE_MAP_WAIT_SEC = 8
local BOSS_FIND_RETRY_INTERVAL_SEC = 0.25
local BOSS_FIND_MAX_ATTEMPTS = 20

local function getBossAttributeName(): string
	return GameSettings.Combat.StageBossAttributeName or "StageBoss"
end

function StageBossLocator.findUnderStageMap(stageMap: Instance): Model?
	local attr = getBossAttributeName()
	for _, child in stageMap:GetChildren() do
		if child:IsA("Model") and child:GetAttribute(attr) == true then
			return child
		end
	end
	return nil
end

--- onProgress(currentCount, totalCount): StageMap이 이 클라이언트 Workspace로 복제되는 동안(StreamingEnabled)
--- 매 재시도마다 호출. totalCount는 서버가 StageMap Clone 직후 기록한 DescendantCount Attribute.
function StageBossLocator.waitForBoss(onProgress: ((current: number, total: number) -> ())?): Model?
	local stageMap = Workspace:WaitForChild(STAGE_MAP_NAME, STAGE_MAP_WAIT_SEC)
	if not stageMap then
		return nil
	end

	pcall(function()
		Players.LocalPlayer:RequestStreamAroundAsync(stageMap:GetPivot().Position)
	end)

	-- DescendantCount Attribute는 StageMap 본체와 함께 복제되지만, 클라이언트에 도착하는
	-- 타이밍이 WaitForChild 반환 시점과 정확히 같지 않을 수 있어 매 tick마다 다시 읽는다.
	local function reportProgress()
		if not onProgress then
			return
		end
		local total = stageMap:GetAttribute("DescendantCount")
		if typeof(total) == "number" and total > 0 then
			onProgress(#stageMap:GetDescendants(), total)
		end
	end

	for _ = 1, BOSS_FIND_MAX_ATTEMPTS do
		reportProgress()
		local boss = StageBossLocator.findUnderStageMap(stageMap)
		if boss then
			reportProgress()
			return boss
		end
		task.wait(BOSS_FIND_RETRY_INTERVAL_SEC)
	end
	return nil
end

function StageBossLocator.getFramingInfo(boss: Model): (Vector3, number, number)
	local ok, cf, size = pcall(function()
		return boss:GetBoundingBox()
	end)
	local center: Vector3
	local height: number
	if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
		center = cf.Position
		height = size.Y
	else
		center = boss:GetPivot().Position
		height = 20
	end

	local lookAt = center + Vector3.new(0, height * 0.35, 0)
	local standOff = math.max(height * 1.2, 30)
	return lookAt, standOff, height
end

function StageBossLocator.getLookAtPosition(boss: Model): Vector3
	local lookAt, _, _ = StageBossLocator.getFramingInfo(boss)
	return lookAt
end

return StageBossLocator
