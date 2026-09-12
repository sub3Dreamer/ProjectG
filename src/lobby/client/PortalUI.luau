--[[
	PortalUI (lobby client)

	ReplicatedStorage.Client.PortalUI.BillboardGui 를 템플릿으로 사용해
	Workspace 안 Portal=true 모델마다 BillboardGui 를 PlayerGui 에 복제 배치한다.

	BillboardGui 가 PlayerGui 에 있어야 안의 GuiButton(ExitButton) 입력이 라우팅된다
	(Roblox 사양). Adornee 는 포털 모델 하위 이름이 "Body" 인 BasePart 를 우선 사용하고,
	없으면 PrimaryPart / TouchPart / 기존 탐색 순으로 폴백한다.

	PlaceIds.Stages[StageNumber] 가 없거나 0 이면 BillboardGui 를 만들지 않음 (미연결 스테이지 포털 숨김).

	페데스탈 단위 동작 (자기 stage/diff 와 일치할 때만 활성 표시):
		Idle               → StatusText "0 / {JoinCnt}" (포털 모델 JoinCnt 특성, 1~5)
		PopupOpen(매칭)    → StatusText "제작 중...", Timer/Exit 숨김
		PopupOpen(비매칭)  → Idle 표시
		Recruiting(매칭)   → StatusText "N/cap", Timer "M:SS", Exit (멤버일 때만)
		Recruiting(비매칭) → Idle 표시
		Teleporting(매칭)  → StatusText "순간 이동 중...", Timer/Exit 숨김
		Teleporting(비매칭)→ Idle 표시
]]

local PortalUI = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local LOBBY_PARTY_STATE_EVENT_NAME = "LobbyPartyStateEvent"
local LEAVE_ROOM_EVENT_NAME = "LeaveRoomRequestEvent"

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlaceIds = require(Shared.Config.PlaceIds)
local StringHelper = require(Shared.Helpers.StringHelper)

local PortalWarp = require(script.Parent.PortalWarp)

local TEMPLATE_PARENT_NAMES = { "Client", "PortalUI" }
local TEMPLATE_NAME = "BillboardGui"

local STATE_IDLE = "Idle"
local STATE_POPUP = "PopupOpen"
local STATE_RECRUITING = "Recruiting"
local STATE_TELEPORTING = "Teleporting"

local LOCALE = "kr"

type Pedestal = {
	model: Instance,
	stage: number,
	difficulty: number,
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

--[[
	BillboardGui.Adornee 가 붙을 월드 파트.
	스튜디오에서 포털(SciFiPedestal 등)마다 발광 원판 등으로 "Body" Part 를 두고,
	빌보드가 그 위치·크기에 맞춰 뜨도록 고정한다.
	(이전: PrimaryPart·자식 순 등으로 잡히면 어떤 메시 파트가 잡혀 보일 위치가 들쭉날쭉했음)
]]
local ADORNEE_PART_NAME = "Body"

--- Portal=true 인 Model(BasePart)에서 Adornee용 BasePart 를 고른다.
local function findAdorneePart(model: Instance): BasePart?
	-- 포털 루트가 단일 Part 인 경우 그 자체
	if model:IsA("BasePart") then
		return model :: BasePart
	end
	if model:IsA("Model") then
		local m = model :: Model
		-- 1순위: 모델 트리 안 이름이 Body 인 Part (직계·하위 공통, FindFirstChild 재귀)
		local body = m:FindFirstChild(ADORNEE_PART_NAME, true)
		if body and body:IsA("BasePart") then
			return body :: BasePart
		end
		-- 폴백: 레벨에 Body 가 없을 때만 기존 규칙
		if m.PrimaryPart then
			return m.PrimaryPart
		end
		local explicit = m:FindFirstChild("TouchPart")
		if explicit and explicit:IsA("BasePart") then
			return explicit :: BasePart
		end
		for _, c in m:GetChildren() do
			if c:IsA("BasePart") then
				return c :: BasePart
			end
		end
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				return d :: BasePart
			end
		end
	end
	return nil
end

local function readJoinCntFromPortal(model: Instance): number
	local j = model:GetAttribute("JoinCnt")
	if typeof(j) == "number" then
		return math.clamp(math.floor(j), 1, 5)
	end
	return 5
end

--- RoomManager.getStagePlaceId 와 동일 기준: Stages 테이블에 유효한 PlaceId 가 있을 때만 UI 표시.
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
	p.statusText.Text = string.format("%d / %d", state.current or 0, state.capacity or 0)
	p.timerText.Visible = true
	-- timerText 의 실제 시간 텍스트는 매 프레임 updateCountdowns 에서 갱신
	p.exitButton.Visible = isLocalPlayerInMembers(state)
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
	local matches = (p.stage == state.stageNumber) and (p.difficulty == state.difficulty)
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

--- 서버가 보낸 payload.portal 과 같은 모델의 페데스탈만 갱신(다른 포탈에 영향 없음).
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

-- --- 카운트다운 (Recruiting 의 TimerText 만 매 프레임 갱신) ---

local function updateCountdowns()
	for _, p in ipairs(pedestals) do
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

-- --- 페데스탈 정리 ---

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

-- --- 페데스탈 바인딩 ---

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
	local difficulty = model:GetAttribute("Difficulty")
	if typeof(stage) ~= "number" or typeof(difficulty) ~= "number" then
		return
	end
	if not hasConfiguredStagePlace(stage) then
		return
	end

	-- 월드 기준으로 빌보드가 따라갈 파트 (우선 Body, 없으면 findAdorneePart 폴백)
	local adornee = findAdorneePart(model)
	if not adornee then
		warn("[PortalUI] Adornee 로 사용할 BasePart 없음:", model:GetFullName())
		return
	end

	local bg = (templateBillboard :: BillboardGui):Clone()
	bg.Name = string.format("PortalBillboard_S%d_D%d", stage, difficulty)
	bg.Adornee = adornee -- PlayerGui 안에 있어도 월드 위치는 이 Part 기준
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

	local joinCnt = readJoinCntFromPortal(model)

	local pedestal: Pedestal = {
		model = model,
		stage = stage,
		difficulty = difficulty,
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
		pedestal.joinCnt = readJoinCntFromPortal(model)
		applyStateToPedestal(pedestal, pedestal.lastState)
	end)

	pedestal.exitButton.Activated:Connect(function()
		if leaveRoomEvent then
			leaveRoomEvent:FireServer()
		end
		PortalWarp.warpLocalPlayerToMatch(pedestal.stage, pedestal.difficulty)
	end)

	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			unbindPedestal(model)
		end
	end)

	applyStateToPedestal(pedestal, pedestal.lastState)
	print(
		string.format(
			"[PortalUI] 페데스탈 등록: %s (stage=%d, diff=%d, joinCnt=%d, adornee=%s)",
			model:GetFullName(),
			stage,
			difficulty,
			pedestal.joinCnt,
			adornee:GetFullName()
		)
	)
end

local function scanAll()
	for _, d in Workspace:GetDescendants() do
		if isPortalModel(d) then
			bindPedestal(d)
		end
	end
end

-- --- 템플릿 로드 ---

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

-- --- public ---

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
		scanAll()
		Workspace.DescendantAdded:Connect(function(d: Instance)
			if isPortalModel(d) then
				bindPedestal(d)
			end
		end)
	end)

	Workspace.DescendantRemoving:Connect(function(d: Instance)
		if boundModels[d] then
			unbindPedestal(d)
		end
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
