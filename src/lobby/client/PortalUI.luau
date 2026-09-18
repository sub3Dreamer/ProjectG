--[[
	PortalUI (lobby client)

	ReplicatedStorage.Client.PortalUI.BillboardGui 를 템플릿으로 사용해
	Workspace.Portal 폴더 안 Portal=true 모델마다 BillboardGui 를 PlayerGui 에 복제 배치한다.

	BillboardGui 가 PlayerGui 에 있어야 안의 GuiButton(ExitButton) 입력이 라우팅된다
	(Roblox 사양). Adornee 는 포털 모델 하위 이름이 "Body" 인 BasePart 를 우선 사용하고,
	없으면 PrimaryPart / TouchPart / 기존 탐색 순으로 폴백한다.

	PlaceIds.Stages[StageNumber] 가 없거나 0 이면 BillboardGui 를 만들지 않음 (미연결 스테이지 포털 숨김).

	StageNumber ~= 2 (파티, Difficulty):
		Idle / PopupOpen / Recruiting / Teleporting — stage+difficulty 매칭

	StageNumber == 2 (PVP, Team Red/Blue + PortalNumber):
		Idle / Recruiting / Teleporting — stage+portalNumber+team 매칭
		StatusText "N / JoinCnt" (해당 팀 현황). ExitButton 은 항상 숨김.
]]

local PortalUI = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local LOBBY_PARTY_STATE_EVENT_NAME = "LobbyPartyStateEvent"
local LEAVE_ROOM_EVENT_NAME = "LeaveRoomRequestEvent"
local PVP_STAGE_NUMBER = 2

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlaceIds = require(Shared.Config.PlaceIds)
local StringHelper = require(Shared.Helpers.StringHelper)

local PortalWarp = require(script.Parent.PortalWarp)

local TEMPLATE_PARENT_NAMES = { "Client", "PortalUI" }
local TEMPLATE_NAME = "BillboardGui"
local PORTAL_FOLDER_NAME = "Portal"

local STATE_IDLE = "Idle"
local STATE_POPUP = "PopupOpen"
local STATE_RECRUITING = "Recruiting"
local STATE_TELEPORTING = "Teleporting"

local LOCALE = "kr"

type Pedestal = {
	model: Instance,
	stage: number,
	difficulty: number?,
	team: string?,
	portalNumber: number?,
	isPvp: boolean,
	joinCnt: number,
	joinCntAttrConn: RBXScriptConnection?,
	billboardGui: BillboardGui,
	statusText: TextLabel,
	timerText: TextLabel,
	exitButton: GuiButton,
	lastState: any,
}

local pedestals: { Pedestal } = {}
local boundModels: { [Instance]: boolean } = {}
local leaveRoomEvent: RemoteEvent? = nil
local localPlayer = Players.LocalPlayer
local playerGui: PlayerGui? = nil
local templateBillboard: BillboardGui? = nil
local initialized = false

-- --- 유틸 ---

local function isPortalModel(inst: Instance): boolean
	if not (inst:IsA("Model") or inst:IsA("BasePart")) then
		return false
	end
	return inst:GetAttribute("Portal") == true
end

local function isValidTeam(team: any): boolean
	return team == "Red" or team == "Blue"
end

local ADORNEE_PART_NAME = "Body"

local function findAdorneePart(model: Instance): BasePart?
	if model:IsA("BasePart") then
		return model :: BasePart
	end
	if model:IsA("Model") then
		local m = model :: Model
		local body = m:FindFirstChild(ADORNEE_PART_NAME, true)
		if body and body:IsA("BasePart") then
			return body :: BasePart
		end
		if m.PrimaryPart then
			return m.PrimaryPart
		end
		local explicit = m:FindFirstChild("TouchPart")
		if explicit and explicit:IsA("BasePart") then
			return explicit :: BasePart
		end
		for _, c in m:GetChildren() do
			if c:IsA("BasePart") then
				return c
			end
		end
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				return d
			end
		end
	end
	return nil
end

local function readJoinCntFromPortal(model: Instance, isPvp: boolean): number
	local maxCap = if isPvp then 2 else 5
	local j = model:GetAttribute("JoinCnt")
	if typeof(j) == "number" then
		return math.clamp(math.floor(j), 1, maxCap)
	end
	return maxCap
end

local function hasConfiguredStagePlace(stageNumber: number): boolean
	if typeof(stageNumber) ~= "number" or stageNumber < 1 then
		return false
	end
	local id = PlaceIds.Stages[stageNumber]
	return typeof(id) == "number" and id ~= 0
end

local function formatMmSs(seconds: number): string
	local s = math.max(0, math.floor(seconds + 0.5))
	local m = math.floor(s / 60)
	local r = s % 60
	return string.format("%d : %02d", m, r)
end

local function isLocalPlayerInMembers(state: any): boolean
	if not (state and state.memberUserIds) then
		return false
	end
	for _, uid in ipairs(state.memberUserIds) do
		if uid == localPlayer.UserId then
			return true
		end
	end
	return false
end

local function pedestalMatchesState(p: Pedestal, state: any): boolean
	if not state then
		return false
	end
	if p.stage ~= state.stageNumber then
		return false
	end
	if p.isPvp then
		if p.team == nil or p.team ~= state.team then
			return false
		end
		if p.portalNumber == nil or p.portalNumber ~= state.portalNumber then
			return false
		end
		return true
	end
	return p.difficulty ~= nil and p.difficulty == state.difficulty
end

-- --- pedestal 단일 표시 헬퍼 ---

local function applyIdle(p: Pedestal)
	p.statusText.Visible = true
	p.statusText.Text = string.format("0 / %d", p.joinCnt)
	p.timerText.Visible = false
	p.exitButton.Visible = false
end

local function applyPopupMatching(p: Pedestal)
	p.statusText.Visible = true
	p.statusText.Text = StringHelper.get("Portal_Preparing", LOCALE)
	p.timerText.Visible = false
	p.exitButton.Visible = false
end

local function applyRecruitingMatching(p: Pedestal, state: any)
	p.statusText.Visible = true
	p.statusText.Text = string.format("%d / %d", state.current or 0, state.capacity or p.joinCnt)
	-- PVP 는 모집 타이머·Exit 없음 (StatusText 만 갱신)
	if p.isPvp then
		p.timerText.Visible = false
		p.exitButton.Visible = false
	else
		p.timerText.Visible = true
		p.exitButton.Visible = isLocalPlayerInMembers(state)
	end
end

local function applyTeleportingMatching(p: Pedestal)
	p.statusText.Visible = true
	p.statusText.Text = StringHelper.get("Portal_Teleporting", LOCALE)
	p.timerText.Visible = false
	p.exitButton.Visible = false
end

local function applyStateToPedestal(p: Pedestal, state: any)
	if not state or state.state == STATE_IDLE then
		applyIdle(p)
		return
	end
	local matches = pedestalMatchesState(p, state)
	if state.state == STATE_POPUP then
		if matches then
			applyPopupMatching(p)
		else
			applyIdle(p)
		end
	elseif state.state == STATE_RECRUITING then
		if matches then
			applyRecruitingMatching(p, state)
		else
			applyIdle(p)
		end
	elseif state.state == STATE_TELEPORTING then
		if matches then
			applyTeleportingMatching(p)
		else
			applyIdle(p)
		end
	else
		applyIdle(p)
	end
end

local function applyStateToPortal(state: any)
	if not (state and state.portal) then
		return
	end
	for _, p in ipairs(pedestals) do
		if p.model == state.portal then
			p.lastState = state
			applyStateToPedestal(p, state)
			return
		end
	end
end

local function updateCountdowns()
	for _, p in ipairs(pedestals) do
		if not p.isPvp then
			local s = p.lastState
			if s and s.state == STATE_RECRUITING and s.recruitDeadline then
				local remaining = (s.recruitDeadline :: number) - workspace:GetServerTimeNow()
				if remaining < 0 then
					remaining = 0
				end
				p.timerText.Text = formatMmSs(remaining)
			end
		end
	end
end

local function unbindPedestal(model: Instance)
	if not boundModels[model] then
		return
	end
	boundModels[model] = nil
	for i = #pedestals, 1, -1 do
		local p = pedestals[i]
		if p.model == model then
			if p.joinCntAttrConn then
				p.joinCntAttrConn:Disconnect()
				p.joinCntAttrConn = nil
			end
			if p.billboardGui then
				p.billboardGui:Destroy()
			end
			table.remove(pedestals, i)
		end
	end
end

local function bindPedestal(model: Instance)
	if boundModels[model] then
		return
	end
	if not isPortalModel(model) then
		return
	end
	if not (templateBillboard and playerGui) then
		return
	end

	local stage = model:GetAttribute("StageNumber")
	if typeof(stage) ~= "number" then
		return
	end
	if not hasConfiguredStagePlace(stage) then
		return
	end

	local isPvp = isValidTeam(model:GetAttribute("Team")) or stage == PVP_STAGE_NUMBER
	local difficulty: number? = nil
	local team: string? = nil
	local portalNumber: number? = nil
	if isPvp then
		local t = model:GetAttribute("Team")
		if not isValidTeam(t) then
			return
		end
		team = t :: string
		local pn = model:GetAttribute("PortalNumber")
		if typeof(pn) ~= "number" or pn < 1 then
			return
		end
		portalNumber = math.floor(pn)
	else
		local d = model:GetAttribute("Difficulty")
		if typeof(d) ~= "number" then
			return
		end
		difficulty = d
	end

	local adornee = findAdorneePart(model)
	if not adornee then
		warn("[PortalUI] Adornee 로 사용할 BasePart 없음:", model:GetFullName())
		return
	end

	local bg = (templateBillboard :: BillboardGui):Clone()
	if isPvp then
		bg.Name = string.format("PortalBillboard_S%d_P%d_%s", stage, portalNumber, team)
	else
		bg.Name = string.format("PortalBillboard_S%d_D%d", stage, difficulty)
	end
	bg.Adornee = adornee
	bg.Active = true

	local statusInst = bg:FindFirstChild("StatusText")
	local timerInst = bg:FindFirstChild("TimerText")
	local exitInst = bg:FindFirstChild("ExitButton")
	if not (statusInst and statusInst:IsA("TextLabel")) then
		warn("[PortalUI] 템플릿에 StatusText(TextLabel) 없음")
		bg:Destroy()
		return
	end
	if not (timerInst and timerInst:IsA("TextLabel")) then
		warn("[PortalUI] 템플릿에 TimerText(TextLabel) 없음")
		bg:Destroy()
		return
	end
	if not (exitInst and exitInst:IsA("GuiButton")) then
		warn("[PortalUI] 템플릿에 ExitButton(GuiButton) 없음")
		bg:Destroy()
		return
	end

	bg.Parent = playerGui

	local joinCnt = readJoinCntFromPortal(model, isPvp)

	local pedestal: Pedestal = {
		model = model,
		stage = stage,
		difficulty = difficulty,
		team = team,
		portalNumber = portalNumber,
		isPvp = isPvp,
		joinCnt = joinCnt,
		joinCntAttrConn = nil,
		billboardGui = bg,
		statusText = statusInst :: TextLabel,
		timerText = timerInst :: TextLabel,
		exitButton = exitInst :: GuiButton,
		lastState = nil,
	}
	table.insert(pedestals, pedestal)
	boundModels[model] = true

	pedestal.joinCntAttrConn = model:GetAttributeChangedSignal("JoinCnt"):Connect(function()
		pedestal.joinCnt = readJoinCntFromPortal(model, isPvp)
		applyStateToPedestal(pedestal, pedestal.lastState)
	end)

	-- PVP: Billboard Exit 미사용 (팝업에서만 퇴장). 파티만 Exit 연결.
	if not isPvp then
		pedestal.exitButton.Activated:Connect(function()
			if leaveRoomEvent then
				leaveRoomEvent:FireServer()
			end
			if pedestal.difficulty then
				PortalWarp.warpLocalPlayerToMatch(pedestal.stage, pedestal.difficulty)
			end
		end)
	else
		pedestal.exitButton.Visible = false
	end

	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			unbindPedestal(model)
		end
	end)

	applyStateToPedestal(pedestal, pedestal.lastState)
	if isPvp then
		print(
			string.format(
				"[PortalUI] PVP 페데스탈 등록: %s (stage=%d, portalNumber=%d, team=%s, joinCnt=%d, adornee=%s)",
				model:GetFullName(),
				stage,
				portalNumber :: number,
				tostring(team),
				pedestal.joinCnt,
				adornee:GetFullName()
			)
		)
	else
		print(
			string.format(
				"[PortalUI] 페데스탈 등록: %s (stage=%d, diff=%d, joinCnt=%d, adornee=%s)",
				model:GetFullName(),
				stage,
				difficulty :: number,
				pedestal.joinCnt,
				adornee:GetFullName()
			)
		)
	end
end

local function resolvePortalFolder(): Folder?
	local folder = Workspace:WaitForChild(PORTAL_FOLDER_NAME, 10)
	if not (folder and folder:IsA("Folder")) then
		warn("[PortalUI] Workspace.", PORTAL_FOLDER_NAME, " 폴더 없음")
		return nil
	end
	return folder :: Folder
end

local function scanAll(portalFolder: Folder)
	for _, d in portalFolder:GetDescendants() do
		if isPortalModel(d) then
			bindPedestal(d)
		end
	end
end

local function resolveTemplate(): BillboardGui?
	local node: Instance = ReplicatedStorage
	for _, name in TEMPLATE_PARENT_NAMES do
		local nxt = node:WaitForChild(name, 10)
		if not nxt then
			warn("[PortalUI] 템플릿 부모 경로 누락:", name)
			return nil
		end
		node = nxt
	end
	local tpl = node:WaitForChild(TEMPLATE_NAME, 10)
	if not (tpl and tpl:IsA("BillboardGui")) then
		warn("[PortalUI] 템플릿 BillboardGui 누락:", TEMPLATE_NAME)
		return nil
	end
	return tpl :: BillboardGui
end

function PortalUI.init()
	if initialized then
		return
	end
	initialized = true

	playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	task.spawn(function()
		templateBillboard = resolveTemplate()
		if not templateBillboard then
			return
		end
		local portalFolder = resolvePortalFolder()
		if not portalFolder then
			return
		end
		scanAll(portalFolder)
		portalFolder.DescendantAdded:Connect(function(d: Instance)
			if isPortalModel(d) then
				bindPedestal(d)
			end
		end)
		portalFolder.DescendantRemoving:Connect(function(d: Instance)
			if boundModels[d] then
				unbindPedestal(d)
			end
		end)
	end)

	task.spawn(function()
		leaveRoomEvent = ReplicatedStorage:WaitForChild(LEAVE_ROOM_EVENT_NAME) :: RemoteEvent
	end)

	task.spawn(function()
		local stateEv = ReplicatedStorage:WaitForChild(LOBBY_PARTY_STATE_EVENT_NAME) :: RemoteEvent
		stateEv.OnClientEvent:Connect(function(payload)
			if typeof(payload) ~= "table" then
				return
			end
			applyStateToPortal(payload)
		end)
	end)

	RunService.Heartbeat:Connect(updateCountdowns)

	print("[PortalUI] 초기화 완료")
end

return PortalUI
