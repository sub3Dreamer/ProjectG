--[[
	PvpPopup (lobby client)

	GUI 트리: PopupScreenGui.Content.PvpPopup
		Container
			Team_Blue / Team_Red
				Profiles
					Profile (x2)
						ImgProfile : ImageLabel
						TxtNickname (또는 TxtNickName) : TextLabel
						Loading : Frame
			ExitButton : TextButton
		Top.CloseButton : TextButton

	슬롯:
	  - 플레이어 있음 → ImgProfile / 닉네임 Visible, Loading Hidden
	  - 플레이어 없음 → ImgProfile / 닉네임 Hidden, Loading Visible
	  - 팀당 최대 2명. 입장 시 PlayerInfo { UserId, DisplayName, Team }

	동기화:
	  - 서버가 PvpPopupStateEvent 로 전체 로스터를 입장 중인 전원에게 브로드캐스트
	  - PlayerInfo.Team 으로 Blue/Red 슬롯에 배치
	  - 로컬 플레이어가 로스터에 있으면 open/갱신, 없으면 팝업 닫기
	  - ExitButton / CloseButton → LeavePvpRequestEvent 후 팝업 닫기
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)
local StringBinder = require(Shared.Helpers.StringBinder)

local PortalWarp = require(script.Parent.Parent.PortalWarp)

local PvpPopup = {}

local POPUP_ROOT_NAME = "PvpPopup"
local TEAM_CAPACITY = 2
local PVP_STAGE_NUMBER = 2
local THUMBNAIL_TYPE = Enum.ThumbnailType.HeadShot
local THUMBNAIL_SIZE = Enum.ThumbnailSize.Size150x150

local PVP_STATE_EVENT_NAME = "PvpPopupStateEvent"
local LEAVE_PVP_EVENT_NAME = "LeavePvpRequestEvent"

export type TeamId = "Blue" | "Red"

export type PlayerInfo = {
	UserId: number,
	DisplayName: string,
	Team: TeamId,
}

export type PvpRoster = {
	Blue: { PlayerInfo },
	Red: { PlayerInfo },
}

type ProfileSlot = {
	root: GuiObject,
	imgProfile: ImageLabel,
	txtNickname: TextLabel,
	loading: GuiObject,
	loadToken: number,
}

type TeamSlots = { ProfileSlot }

type ActiveSession = {
	close: () -> (),
	applyRoster: (roster: PvpRoster) -> (),
}

local initialized = false
local activeSession: ActiveSession? = nil
local currentRoster: PvpRoster = { Blue = {}, Red = {} }
local currentPortalNumber: number? = nil

local function prepareClickableButton(button: GuiButton)
	button.Active = true
	if button:IsA("GuiObject") then
		local gui = button :: GuiObject
		gui.ZIndex = math.max(gui.ZIndex, 2)
	end
	pcall(function()
		(button :: any).Interactable = true
	end)
end

local function cloneRoster(roster: PvpRoster): PvpRoster
	local blue = table.clone(roster.Blue)
	local red = table.clone(roster.Red)
	return { Blue = blue, Red = red }
end

local function emptyRoster(): PvpRoster
	return { Blue = {}, Red = {} }
end

local function normalizeTeamId(raw: any): TeamId?
	if raw == "Blue" or raw == "blue" then
		return "Blue"
	end
	if raw == "Red" or raw == "red" then
		return "Red"
	end
	return nil
end

local function normalizePlayerInfo(raw: any, fallbackTeam: TeamId?): PlayerInfo?
	if typeof(raw) ~= "table" then
		return nil
	end
	local userId = tonumber(raw.UserId)
	local displayName = raw.DisplayName
	if not userId or userId ~= userId or userId < 1 then
		return nil
	end
	if typeof(displayName) ~= "string" or displayName == "" then
		local player = Players:GetPlayerByUserId(math.floor(userId))
		if player then
			displayName = player.DisplayName
		else
			return nil
		end
	end
	local team = normalizeTeamId(raw.Team) or fallbackTeam
	if not team then
		return nil
	end
	return {
		UserId = math.floor(userId),
		DisplayName = displayName,
		Team = team,
	}
end

local function appendUnique(players: { PlayerInfo }, info: PlayerInfo)
	for _, existing in players do
		if existing.UserId == info.UserId then
			return
		end
	end
	if #players >= TEAM_CAPACITY then
		return
	end
	table.insert(players, info)
end

local function normalizeTeamPlayers(raw: any, team: TeamId): { PlayerInfo }
	local players: { PlayerInfo } = {}
	if typeof(raw) ~= "table" then
		return players
	end
	for _, entry in raw do
		local info = normalizePlayerInfo(entry, team)
		if info and info.Team == team then
			appendUnique(players, info)
		end
		if #players >= TEAM_CAPACITY then
			break
		end
	end
	return players
end

--- Blue/Red 배열 + PlayerInfo.Team 기준으로 슬롯용 로스터를 만든다.
--- Members(flat) 가 있으면 Team 필드로 분배한다.
local function normalizeRoster(raw: any): PvpRoster
	if typeof(raw) ~= "table" then
		return emptyRoster()
	end

	local roster = emptyRoster()

	local flat = raw.Members or raw.members or raw.Players or raw.players
	if typeof(flat) == "table" then
		for _, entry in flat do
			local info = normalizePlayerInfo(entry, nil)
			if info then
				appendUnique(roster[info.Team], info)
			end
		end
	end

	for _, info in normalizeTeamPlayers(raw.Blue or raw.blue, "Blue") do
		appendUnique(roster.Blue, info)
	end
	for _, info in normalizeTeamPlayers(raw.Red or raw.red, "Red") do
		appendUnique(roster.Red, info)
	end

	return roster
end

local function rosterContains(roster: PvpRoster, userId: number): boolean
	for _, info in roster.Blue do
		if info.UserId == userId then
			return true
		end
	end
	for _, info in roster.Red do
		if info.UserId == userId then
			return true
		end
	end
	return false
end

local function findPlayerTeam(roster: PvpRoster, userId: number): TeamId?
	for _, info in roster.Blue do
		if info.UserId == userId then
			return info.Team
		end
	end
	for _, info in roster.Red do
		if info.UserId == userId then
			return info.Team
		end
	end
	return nil
end

local function getPvpPopupRoot(): GuiObject?
	if not PopupManager.getRootGui() then
		PopupManager.init()
	end
	local content = PopupManager.getContentFrame()
	if not content then
		return nil
	end
	local rootInst = content:FindFirstChild(POPUP_ROOT_NAME)
	if rootInst and rootInst:IsA("GuiObject") then
		return rootInst :: GuiObject
	end
	return nil
end

local function findNicknameLabel(profile: Instance): TextLabel?
	local nick = profile:FindFirstChild("TxtNickname") or profile:FindFirstChild("TxtNickName")
	if nick and nick:IsA("TextLabel") then
		return nick :: TextLabel
	end
	return nil
end

local function collectProfileSlots(profiles: Instance): TeamSlots?
	local frames: { GuiObject } = {}
	for _, child in profiles:GetChildren() do
		if child.Name == "Profile" and child:IsA("GuiObject") then
			table.insert(frames, child :: GuiObject)
		end
	end
	table.sort(frames, function(a, b)
		if a.LayoutOrder ~= b.LayoutOrder then
			return a.LayoutOrder < b.LayoutOrder
		end
		return a.Name < b.Name
	end)

	if #frames < TEAM_CAPACITY then
		return nil
	end

	local slots: TeamSlots = {}
	for i = 1, TEAM_CAPACITY do
		local frame = frames[i]
		local img = frame:FindFirstChild("ImgProfile")
		local nick = findNicknameLabel(frame)
		local loading = frame:FindFirstChild("Loading")
		if not (img and img:IsA("ImageLabel")) then
			return nil
		end
		if not nick then
			return nil
		end
		if not (loading and loading:IsA("GuiObject")) then
			return nil
		end
		table.insert(slots, {
			root = frame,
			imgProfile = img :: ImageLabel,
			txtNickname = nick,
			loading = loading :: GuiObject,
			loadToken = 0,
		})
	end
	return slots
end

local function resolveTeamSlots(rootGui: GuiObject): { Blue: TeamSlots, Red: TeamSlots }?
	local container = rootGui:FindFirstChild("Container")
	if not container then
		warn("[PvpPopup] Container 없음")
		return nil
	end

	local function resolveTeam(teamName: string): TeamSlots?
		local team = container:FindFirstChild(teamName)
		if not team then
			warn("[PvpPopup]", teamName, "없음")
			return nil
		end
		local profiles = team:FindFirstChild("Profiles")
		if not profiles then
			warn("[PvpPopup]", teamName, "Profiles 없음")
			return nil
		end
		local slots = collectProfileSlots(profiles)
		if not slots then
			warn("[PvpPopup]", teamName, "Profile 슬롯(ImgProfile / TxtNickname / Loading) 없음")
			return nil
		end
		return slots
	end

	local blue = resolveTeam("Team_Blue")
	local red = resolveTeam("Team_Red")
	if not (blue and red) then
		return nil
	end
	return { Blue = blue, Red = red }
end

local function resolveLeaveButtons(rootGui: GuiObject): (GuiButton?, GuiButton?)
	local container = rootGui:FindFirstChild("Container")
	local exitInst = container and container:FindFirstChild("ExitButton")
	local exitBtn = (exitInst and exitInst:IsA("GuiButton")) and (exitInst :: GuiButton) or nil

	local top = rootGui:FindFirstChild("Top")
	local closeInst = top and top:FindFirstChild("CloseButton")
	local closeBtn = (closeInst and closeInst:IsA("GuiButton")) and (closeInst :: GuiButton) or nil

	return exitBtn, closeBtn
end

local function clearSlot(slot: ProfileSlot)
	slot.loadToken += 1
	slot.imgProfile.Image = ""
	slot.imgProfile.Visible = false
	slot.txtNickname.Text = ""
	slot.txtNickname.Visible = false
	slot.loading.Visible = true
end

local function applyPlayerToSlot(slot: ProfileSlot, info: PlayerInfo)
	slot.loadToken += 1
	local token = slot.loadToken

	slot.txtNickname.Text = info.DisplayName
	slot.txtNickname.Visible = true
	slot.imgProfile.Visible = true
	slot.loading.Visible = false

	task.spawn(function()
		local ok, content = pcall(function()
			local image, _isReady = Players:GetUserThumbnailAsync(info.UserId, THUMBNAIL_TYPE, THUMBNAIL_SIZE)
			return image
		end)
		if token ~= slot.loadToken then
			return
		end
		if ok and typeof(content) == "string" then
			slot.imgProfile.Image = content
		else
			slot.imgProfile.Image = ""
		end
	end)
end

local function renderTeam(slots: TeamSlots, players: { PlayerInfo })
	for i = 1, TEAM_CAPACITY do
		local info = players[i]
		if info then
			applyPlayerToSlot(slots[i], info)
		else
			clearSlot(slots[i])
		end
	end
end

local function renderRoster(teamSlots: { Blue: TeamSlots, Red: TeamSlots }, roster: PvpRoster)
	-- Team 필드로 한 번 더 정렬해 슬롯 배치 (Blue→Team_Blue, Red→Team_Red)
	local bluePlayers: { PlayerInfo } = {}
	local redPlayers: { PlayerInfo } = {}
	for _, info in roster.Blue do
		if info.Team == "Blue" then
			appendUnique(bluePlayers, info)
		elseif info.Team == "Red" then
			appendUnique(redPlayers, info)
		end
	end
	for _, info in roster.Red do
		if info.Team == "Red" then
			appendUnique(redPlayers, info)
		elseif info.Team == "Blue" then
			appendUnique(bluePlayers, info)
		end
	end
	renderTeam(teamSlots.Blue, bluePlayers)
	renderTeam(teamSlots.Red, redPlayers)
end

local function requestLeave()
	local leaveEvent = ReplicatedStorage:FindFirstChild(LEAVE_PVP_EVENT_NAME)
	if leaveEvent and leaveEvent:IsA("RemoteEvent") then
		leaveEvent:FireServer()
	else
		warn("[PvpPopup] LeavePvpRequestEvent 없음 — 로컬 닫기만 수행")
	end
	local team = findPlayerTeam(currentRoster, Players.LocalPlayer.UserId)
	if team then
		PortalWarp.warpLocalPlayerToTeam(PVP_STAGE_NUMBER, team, currentPortalNumber)
	end
end

function PvpPopup.open(state: any)
	local roster = normalizeRoster(state)
	if typeof(state) == "table" and typeof(state.portalNumber) == "number" then
		currentPortalNumber = math.floor(state.portalNumber)
	end
	if activeSession then
		activeSession.applyRoster(roster)
		return
	end

	local rootGui = getPvpPopupRoot()
	if not rootGui then
		warn("[PvpPopup] Content.PvpPopup 없음")
		return
	end
	StringBinder.applySubtreeOnce(rootGui)

	local teamSlots = resolveTeamSlots(rootGui)
	if not teamSlots then
		return
	end

	local exitBtn, closeBtn = resolveLeaveButtons(rootGui)
	if not exitBtn then
		warn("[PvpPopup] Container.ExitButton 없음")
		return
	end
	if not closeBtn then
		warn("[PvpPopup] Top.CloseButton 없음")
		return
	end

	local content = PopupManager.getContentFrame()
	if not content then
		warn("[PvpPopup] Content 없음 (PopupScreenGui.Content 확인)")
		return
	end

	local contentGui = content :: GuiObject
	local prevContentActive = contentGui.Active
	local prevRootActive = rootGui.Active
	local wasRootVis = rootGui.Visible
	contentGui.Active = false
	rootGui.Active = false

	local closed = false
	local connections: { RBXScriptConnection } = {}
	currentRoster = cloneRoster(roster)

	local function close()
		if closed then
			return
		end
		closed = true
		for _, c in ipairs(connections) do
			c:Disconnect()
		end
		for _, slot in teamSlots.Blue do
			clearSlot(slot)
		end
		for _, slot in teamSlots.Red do
			clearSlot(slot)
		end
		currentRoster = emptyRoster()
		currentPortalNumber = nil
		rootGui.Visible = wasRootVis
		contentGui.Active = prevContentActive
		rootGui.Active = prevRootActive
		PopupManager.popPopup()
		PopupManager.setPopupOpenBlocked(false)
		if activeSession and activeSession.close == close then
			activeSession = nil
		end
	end

	local function applyRoster(nextRoster: PvpRoster)
		currentRoster = cloneRoster(nextRoster)
		renderRoster(teamSlots, currentRoster)
	end

	local pushOptions = {
		dim = false,
		blockInput = false,
		close = close,
		closeOthers = true,
		playEntranceAnimation = true,
		rootGui = rootGui,
	}
	if not PopupManager.pushPopup(pushOptions) then
		contentGui.Active = prevContentActive
		rootGui.Active = prevRootActive
		return
	end
	PopupManager.setPopupOpenBlocked(true)
	rootGui.Visible = true
	if pushOptions.playEntranceAnimation then
		PopupManager.playBounceEntrance(rootGui)
	end

	applyRoster(currentRoster)

	local function onLeaveClicked()
		requestLeave()
		close()
	end

	prepareClickableButton(exitBtn)
	prepareClickableButton(closeBtn)
	table.insert(connections, exitBtn.Activated:Connect(onLeaveClicked))
	table.insert(connections, closeBtn.Activated:Connect(onLeaveClicked))

	activeSession = {
		close = close,
		applyRoster = applyRoster,
	}
end

function PvpPopup.setState(state: any)
	local roster = normalizeRoster(state)
	if typeof(state) == "table" and typeof(state.portalNumber) == "number" then
		currentPortalNumber = math.floor(state.portalNumber)
	end
	local localUserId = Players.LocalPlayer.UserId
	if not rosterContains(roster, localUserId) then
		PvpPopup.close()
		return
	end
	if activeSession then
		activeSession.applyRoster(roster)
	else
		PvpPopup.open(state)
	end
end

function PvpPopup.addPlayer(team: TeamId, playerInfo: any)
	if team ~= "Blue" and team ~= "Red" then
		warn("[PvpPopup] 잘못된 팀:", team)
		return
	end
	local info = normalizePlayerInfo(playerInfo, team)
	if not info then
		warn("[PvpPopup] 잘못된 PlayerInfo:", playerInfo)
		return
	end

	local roster = emptyRoster()
	if activeSession then
		warn("[PvpPopup] addPlayer는 팝업이 닫혀 있을 때 초기 입장용입니다. 실시간 갱신은 setState를 사용하세요.")
	end

	if findPlayerTeam(roster, info.UserId) then
		return
	end
	if #roster[team] >= TEAM_CAPACITY then
		warn("[PvpPopup]", team, "팀 정원 초과")
		return
	end
	info.Team = team
	table.insert(roster[team], info)
	PvpPopup.setState(roster)
end

function PvpPopup.close()
	if activeSession then
		activeSession.close()
	end
end

function PvpPopup.init()
	if initialized then
		return
	end
	initialized = true

	task.spawn(function()
		local stateEv = ReplicatedStorage:WaitForChild(PVP_STATE_EVENT_NAME) :: RemoteEvent
		stateEv.OnClientEvent:Connect(function(payload)
			PvpPopup.setState(payload)
		end)
	end)

	print("[PvpPopup] 초기화 완료")
end

return PvpPopup
