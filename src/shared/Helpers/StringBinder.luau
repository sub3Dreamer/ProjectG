--[[
	StringBinder (shared / client UI)

	TextLabel·TextButton에 Attribute StringKey 가 있으면 StringData.kr Text 적용.
	로케일은 항상 "kr" (en은 StringData 참고용).

	LobbyScreenGui: applySubtree (시작 시 1회)
	팝업 루트: applySubtreeOnce (해당 팝업 최초 open 시 1회)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StringHelper = require(Shared.Helpers.StringHelper)

local StringBinder = {}

local STRING_KEY_ATTRIBUTE = "StringKey"
local LOCALE = "kr"

local boundRoots: { [Instance]: boolean } = {}

local function isBindableTextGui(inst: Instance): boolean
	return inst:IsA("TextLabel") or inst:IsA("TextButton")
end

function StringBinder.apply(inst: Instance): boolean
	if not isBindableTextGui(inst) then
		return false
	end
	local key = inst:GetAttribute(STRING_KEY_ATTRIBUTE)
	if typeof(key) ~= "string" or key == "" then
		return false
	end
	local textGui = inst :: TextLabel | TextButton
	textGui.Text = StringHelper.get(key, LOCALE)
	return true
end

function StringBinder.applySubtree(root: Instance)
	if isBindableTextGui(root) then
		StringBinder.apply(root)
	end
	for _, descendant in root:GetDescendants() do
		StringBinder.apply(descendant)
	end
end

function StringBinder.applySubtreeOnce(root: Instance)
	if boundRoots[root] then
		return
	end
	boundRoots[root] = true
	StringBinder.applySubtree(root)
end

function StringBinder.isSubtreeBound(root: Instance): boolean
	return boundRoots[root] == true
end

StringBinder.STRING_KEY_ATTRIBUTE = STRING_KEY_ATTRIBUTE
StringBinder.LOCALE = LOCALE

return StringBinder
