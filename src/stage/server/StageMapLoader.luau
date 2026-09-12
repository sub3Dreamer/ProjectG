--[[
	ServerStorage.StageMap 템플릿(Part)을 Workspace로 clone.
	각 Stage 플레이스마다 ServerStorage에 맵 Part 1개(StageMap)만 두면 됨.
]]

local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local StageMapLoader = {}

local TEMPLATE_NAME = "StageMap"
local LOADED_NAME = "StageMap"

function StageMapLoader.load(): Instance?
	local existing = Workspace:FindFirstChild(LOADED_NAME)
	if existing then
		warn("[StageMapLoader] Workspace에 이미 로드됨:", existing:GetFullName())
		return existing
	end

	local template = ServerStorage:FindFirstChild(TEMPLATE_NAME)
	if not template then
		warn("[StageMapLoader] ServerStorage.", TEMPLATE_NAME, " 없음 — 맵 로드 스킵")
		return nil
	end
	if not template:IsA("Part") then
		warn("[StageMapLoader] StageMap은 Part여야 함:", template.ClassName)
		return nil
	end

	local map = template:Clone() :: Part
	map.Name = LOADED_NAME
	map:SetAttribute("DescendantCount", #map:GetDescendants())
	map.Parent = Workspace

	print("[StageMapLoader] 맵 로드 완료:", map:GetFullName())
	return map
end

return StageMapLoader
