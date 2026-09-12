--[[
	Stage 진입 시 BossIntroPopup 이전, StageMap이 클라이언트 Workspace로 복제되길
	기다리는 동안(StreamingEnabled) currentCount/totalCount 진행도를 표시.
	ReplicatedFirst.LoadingScreenGui GUI가 아직 없으면 경고만 남기고 안전하게 스킵.

	GUI 구조: ReplicatedFirst.LoadingScreenGui(ScreenGui) > Content > LoadingPopup > Frame >
		(ImgMap: ImageLabel, TxtPercent: TextLabel, TxtProgress: TextLabel)
	PopupManager(PlayerGui.PopupScreenGui)와 무관한 별도 화면이라 직접 PlayerGui로 옮겨 표시한다.
]]

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlaceManager = require(Shared.Managers.PlaceManager)
local StageHelper = require(Shared.Helpers.StageHelper)

local LoadingPopup = {}

--- false면 show()가 즉시 스킵 (코드/GUI 구조는 유지, 노출 방식 재검토 중).
LoadingPopup.Enabled = false

local player = Players.LocalPlayer

local popupGui: GuiObject? = nil
local imgMap: ImageLabel? = nil
local txtPercent: TextLabel? = nil
local txtProgress: TextLabel? = nil
local opened = false

local function resolveElements(): boolean
	local screenGui = ReplicatedFirst:FindFirstChild("LoadingScreenGui")
	if not (screenGui and screenGui:IsA("ScreenGui")) then
		return false
	end

	local playerGui = player:FindFirstChild("PlayerGui")
	if playerGui and screenGui.Parent ~= playerGui then
		screenGui.Parent = playerGui
	end

	local content = screenGui:FindFirstChild("Content")
	local popup = content and content:FindFirstChild("LoadingPopup")
	if not (popup and popup:IsA("GuiObject")) then
		return false
	end

	local frame = popup:FindFirstChild("Frame")
	if not (frame and frame:IsA("GuiObject")) then
		return false
	end

	local img = frame:FindFirstChild("ImgMap")
	local percent = frame:FindFirstChild("TxtPercent")
	local progress = frame:FindFirstChild("TxtProgress")

	popupGui = popup
	imgMap = if img and img:IsA("ImageLabel") then img else nil
	txtPercent = if percent and percent:IsA("TextLabel") then percent else nil
	txtProgress = if progress and progress:IsA("TextLabel") then progress else nil
	return true
end

local function applyStageMapImage()
	if not imgMap then
		return
	end
	local _placeType, stageNumber = PlaceManager.getCurrentPlaceType()
	local assetId = StageHelper.getMapImageAssetId(stageNumber)
	if assetId then
		imgMap.Image = assetId
	end
end

--- BossIntroPopup 이전, 맵/보스 대기 시작 시 호출.
function LoadingPopup.show(): boolean
	if not LoadingPopup.Enabled then
		return false
	end
	if opened then
		return true
	end

	if not resolveElements() then
		warn("[LoadingPopup] ReplicatedFirst.LoadingScreenGui.Content.LoadingPopup 을 찾을 수 없습니다 — 스킵")
		return false
	end

	opened = true
	applyStageMapImage()
	LoadingPopup.updateProgress(0, 0)
	;(popupGui :: GuiObject).Visible = true
	return true
end

function LoadingPopup.updateProgress(current: number, total: number)
	if not opened then
		return
	end

	local ratio = if total > 0 then math.clamp(current / total, 0, 1) else 0
	if txtPercent then
		txtPercent.Text = string.format("%d%%", math.round(ratio * 100))
	end
	if txtProgress then
		txtProgress.Text = string.format("Loading Props : %d/%d", current, total)
	end
end

function LoadingPopup.close()
	if not opened then
		return
	end
	opened = false

	if popupGui then
		popupGui.Visible = false
	end
	popupGui = nil
	imgMap = nil
	txtPercent = nil
	txtProgress = nil
end

function LoadingPopup.isOpen(): boolean
	return opened
end

return LoadingPopup
