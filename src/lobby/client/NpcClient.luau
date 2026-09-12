--[[
	NpcClient (lobby client)

	Workspace NPC ProximityPrompt → PopupManager 팝업 연동 (범용).

	Studio 설정:
		NPC의 ProximityPrompt (또는 부모 Model)에 Attribute 추가
			PopupId = "Shop" / "Gacha" / "Relic" / ... (PopupManager.PopupId 값과 동일한 문자열)

	ProximityPrompt.Triggered 시 PopupManager.openPopup(PopupId) 호출.
	StreamingEnabled 대응: Workspace DescendantAdded 로 늦게 로드되는 NPC도 바인딩.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)

local NpcClient = {}

local POPUP_ID_ATTR = "PopupId"

local initialized = false
local boundPrompts: { [ProximityPrompt]: boolean } = {}

local function readPopupId(inst: Instance): string?
	local raw = inst:GetAttribute(POPUP_ID_ATTR)
	if typeof(raw) ~= "string" or raw == "" then
		return nil
	end
	return raw
end

local function resolvePopupId(prompt: ProximityPrompt): string?
	local direct = readPopupId(prompt)
	if direct then
		return direct
	end
	local parent = prompt.Parent
	while parent and parent ~= Workspace do
		local fromAncestor = readPopupId(parent)
		if fromAncestor then
			return fromAncestor
		end
		parent = parent.Parent
	end
	return nil
end

local function tryBindPrompt(inst: Instance)
	if not inst:IsA("ProximityPrompt") then
		return
	end
	local prompt = inst :: ProximityPrompt
	if boundPrompts[prompt] then
		return
	end
	local popupId = resolvePopupId(prompt)
	if not popupId then
		return
	end

	boundPrompts[prompt] = true
	prompt.Triggered:Connect(function(player: Player)
		if player ~= Players.LocalPlayer then
			return
		end
		PopupManager.openPopup(popupId)
	end)
end

local function scan(root: Instance)
	for _, desc in root:GetDescendants() do
		tryBindPrompt(desc)
	end
	root.DescendantAdded:Connect(tryBindPrompt)
end

function NpcClient.init()
	if initialized then
		return
	end
	initialized = true
	scan(Workspace)
	print("[NpcClient] 초기화 완료")
end

return NpcClient
