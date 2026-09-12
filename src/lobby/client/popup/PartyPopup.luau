--[[
	PartyPopup (lobby client)

	GUI 트리: PopupScreenGui.Content.PartyPopup
		Top.CloseButton
		Result
			StageNumberText, DifficultyText, TimerText : TextLabel
			Result.Frame 안: 1Button … 5Button (정원 토글, joinCnt 이하만 표시)
			CreateButton : GuiButton

	흐름:
	  - 포털 Touched → 서버가 PopupOpen + OpenPartyPopupEvent(stage, difficulty, joinCnt)
	  - joinCnt: 포털 JoinCnt(1~5). 토글 최대 개수 및 초기 선택 정원.
	  - 만들기 / 15초 자동 → CreatePartyRequestEvent
	  - 닫기 → CancelPartyRequestEvent
	  - 서버가 PopupOpen이 아니면 LobbyPartyStateEvent로 자동 close

]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PopupManager = require(Shared.Managers.PopupManager)
local StringHelper = require(Shared.Helpers.StringHelper)
local StringBinder = require(Shared.Helpers.StringBinder)
local DifficultyConfig = require(Shared.Config.DifficultyConfig)
local PortalWarp = require(script.Parent.Parent.PortalWarp)

local PartyPopup = {}

local LOCALE = "kr"

local CAPACITY_OPTIONS: { number } = { 1, 2, 3, 4, 5 }
local JOIN_CNT_DEFAULT = 5
local AUTO_CREATE_AFTER_SEC = 15

local CREATE_PARTY_EVENT_NAME = "CreatePartyRequestEvent"
local CANCEL_PARTY_EVENT_NAME = "CancelPartyRequestEvent"
local OPEN_PARTY_POPUP_EVENT_NAME = "OpenPartyPopupEvent"
local LOBBY_PARTY_STATE_EVENT_NAME = "LobbyPartyStateEvent"

local SELECTED_BG = Color3.fromRGB(255, 0, 0)
local DESELECTED_BG = Color3.fromRGB(127, 127, 127)

local initialized = false

local activeSession: { close: () -> (), portal: Instance? }? = nil

local function clampJoinCnt(raw: any): number
	local n = tonumber(raw)
	if not n then
		return JOIN_CNT_DEFAULT
	end
	return math.clamp(math.floor(n), 1, 5)
end

local function findCapacityButton(result: Instance, capacity: number): GuiButton?
	local name = string.format("%dButton", capacity)
	local frame = result:FindFirstChild("Frame")
	if frame then
		local inst = frame:FindFirstChild(name)
		if inst and inst:IsA("GuiButton") then
			return inst :: GuiButton
		end
	end
	local inst = result:FindFirstChild(name)
	if inst and inst:IsA("GuiButton") then
		return inst :: GuiButton
	end
	return nil
end

local function applyCapacityToggleVisual(buttons: { [number]: GuiButton }, selected: number)
	for cap, btn in pairs(buttons) do
		if btn.Visible then
			btn.BackgroundColor3 = (cap == selected) and SELECTED_BG or DESELECTED_BG
		end
	end
end

local function getDifficultyLabel(difficulty: number): string
	local key = DifficultyConfig.labelKeys[difficulty]
	if key then
		return StringHelper.get(key, LOCALE)
	end
	return tostring(difficulty)
end

local function formatStageText(stageNumber: number): string
	return StringHelper.format(StringHelper.get("Party_StageFormat", LOCALE), stageNumber)
end

local function formatDifficultyText(difficulty: number): string
	return StringHelper.format(StringHelper.get("Party_DifficultyFormat", LOCALE), getDifficultyLabel(difficulty))
end

local function formatAutoCreateTimerText(secondsRemaining: number): string
	return StringHelper.format(StringHelper.get("Party_AutoCreateTimer", LOCALE), secondsRemaining)
end

--- 팝업 열기. 이미 열려 있으면 기존 세션을 닫고 새로 연다.
--- portal: 이 팝업이 속한 포탈 인스턴스. LobbyPartyStateEvent 가 다른 포탈에 대한 것이면 이 팝업을 닫지 않기 위해 필요.
function PartyPopup.open(stageNumber: number, difficulty: number, joinCntRaw: any, portal: Instance?)
	if typeof(stageNumber) ~= "number" or stageNumber < 1 then
		warn("[PartyPopup] 잘못된 stageNumber:", stageNumber)
		return
	end
	if not DifficultyConfig.labelKeys[difficulty] then
		warn("[PartyPopup] 잘못된 difficulty(1~3):", difficulty)
		return
	end

	local joinCnt = clampJoinCnt(joinCntRaw)
	if joinCntRaw == nil or tonumber(joinCntRaw) == nil then
		warn("[PartyPopup] joinCnt 없음 →", JOIN_CNT_DEFAULT, "로 표시")
	end

	if not PopupManager.getRootGui() then
		PopupManager.init()
	end
	local content = PopupManager.getContentFrame()
	if not content then
		warn("[PartyPopup] Content 없음 (PopupScreenGui.Content 확인)")
		return
	end

	local root = content:FindFirstChild("PartyPopup")
	if not (root and root:IsA("GuiObject")) then
		warn("[PartyPopup] Content.PartyPopup 을 찾을 수 없습니다")
		return
	end
	local rootGui = root :: GuiObject
	StringBinder.applySubtreeOnce(rootGui)

	local result = root:FindFirstChild("Container")
	if not (result and result:IsA("GuiObject")) then
		warn("[PartyPopup] PartyPopup.Container 없음")
		return
	end

	local stageNumberText = result:FindFirstChild("StageNumberText")
	local difficultyText = result:FindFirstChild("DifficultyText")
	local timerTextInst = result:FindFirstChild("TimerText")
	if not (stageNumberText and stageNumberText:IsA("TextLabel")) then
		warn("[PartyPopup] Result.StageNumberText (TextLabel) 없음")
		return
	end
	if not (difficultyText and difficultyText:IsA("TextLabel")) then
		warn("[PartyPopup] Result.DifficultyText (TextLabel) 없음")
		return
	end
	if not (timerTextInst and timerTextInst:IsA("TextLabel")) then
		warn("[PartyPopup] Result.TimerText (TextLabel) 없음")
		return
	end
	local timerLabel = timerTextInst :: TextLabel

	local createInst = result:FindFirstChild("CreateButton")
	if not (createInst and createInst:IsA("GuiButton")) then
		warn("[PartyPopup] Result.CreateButton (GuiButton) 없음")
		return
	end
	local createBtn = createInst :: GuiButton

	local top = root:FindFirstChild("Top")
	local closeInst = top and top:FindFirstChild("CloseButton")
	if not (closeInst and closeInst:IsA("GuiButton")) then
		warn("[PartyPopup] Top.CloseButton (GuiButton) 없음")
		return
	end
	local closeBtn = closeInst :: GuiButton

	local capacityButtons: { [number]: GuiButton } = {}
	for _, cap in ipairs(CAPACITY_OPTIONS) do
		local btn = findCapacityButton(result, cap)
		if not btn then
			warn(string.format("[PartyPopup] %dButton (GuiButton) 없음 (Result 또는 Result.Frame)", cap))
			return
		end
		capacityButtons[cap] = btn
	end

	(stageNumberText :: TextLabel).Text = formatStageText(stageNumber);
	(difficultyText :: TextLabel).Text = formatDifficultyText(difficulty)

	for cap, btn in pairs(capacityButtons) do
		btn.Visible = cap <= joinCnt
	end

	local selectedCapacity = joinCnt
	applyCapacityToggleVisual(capacityButtons, selectedCapacity)

	local createPartyEvent = ReplicatedStorage:WaitForChild(CREATE_PARTY_EVENT_NAME) :: RemoteEvent
	local cancelPartyEvent = ReplicatedStorage:WaitForChild(CANCEL_PARTY_EVENT_NAME) :: RemoteEvent

	local contentGui = content :: GuiObject
	local prevContentActive = contentGui.Active
	local prevRootActive = rootGui.Active
	contentGui.Active = false
	rootGui.Active = false

	local wasRootVis = rootGui.Visible

	local closed = false
	local createDispatched = false
	local connections: { RBXScriptConnection } = {}

	local function close()
		if closed then
			return
		end
		closed = true
		for _, c in ipairs(connections) do
			c:Disconnect()
		end
		rootGui.Visible = wasRootVis
		contentGui.Active = prevContentActive
		rootGui.Active = prevRootActive
		PopupManager.popPopup()
		PopupManager.setPopupOpenBlocked(false)
		if activeSession and activeSession.close == close then
			activeSession = nil
		end
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

	local function requestCreatePartyAndClose()
		if closed or createDispatched then
			return
		end
		createDispatched = true
		print(
			"[PartyPopup] CreateParty 요청: stage=",
			stageNumber,
			"difficulty=",
			difficulty,
			"capacity=",
			selectedCapacity
		)
		createPartyEvent:FireServer({
			stageNumber = stageNumber,
			difficulty = difficulty,
			capacity = selectedCapacity,
		})
		close()
	end

	for cap, btn in pairs(capacityButtons) do
		table.insert(
			connections,
			btn.Activated:Connect(function()
				if not btn.Visible then
					return
				end
				selectedCapacity = cap
				applyCapacityToggleVisual(capacityButtons, selectedCapacity)
			end)
		)
	end

	table.insert(connections, createBtn.Activated:Connect(requestCreatePartyAndClose))

	table.insert(
		connections,
		closeBtn.Activated:Connect(function()
			print("[PartyPopup] Close 클릭 → CancelPartyRequest")
			cancelPartyEvent:FireServer()
			PortalWarp.warpLocalPlayerToMatch(stageNumber, difficulty)
			close()
		end)
	)

	task.spawn(function()
		for sec = AUTO_CREATE_AFTER_SEC, 0, -1 do
			if closed then
				return
			end
			timerLabel.Text = formatAutoCreateTimerText(sec)
			if sec == 0 then
				if not closed then
					requestCreatePartyAndClose()
				end
				return
			end
			task.wait(1)
		end
	end)

	activeSession = { close = close, portal = portal }
end

function PartyPopup.close()
	if activeSession then
		activeSession.close()
	end
end

function PartyPopup.init()
	if initialized then
		return
	end
	initialized = true

	task.spawn(function()
		local openEv = ReplicatedStorage:WaitForChild(OPEN_PARTY_POPUP_EVENT_NAME) :: RemoteEvent
		openEv.OnClientEvent:Connect(function(payload)
			if typeof(payload) ~= "table" then
				return
			end
			local stage = tonumber(payload.stageNumber)
			local diff = tonumber(payload.difficulty)
			if not (stage and diff) then
				return
			end
			PartyPopup.open(stage, diff, payload.joinCnt, payload.portal)
		end)
	end)

	task.spawn(function()
		local stateEv = ReplicatedStorage:WaitForChild(LOBBY_PARTY_STATE_EVENT_NAME) :: RemoteEvent
		stateEv.OnClientEvent:Connect(function(payload)
			if typeof(payload) ~= "table" then
				return
			end
			-- 다른 포탈에 대한 상태 변화는 이 팝업과 무관하므로 무시(포탈별 독립 파티 지원).
			if not activeSession or payload.portal ~= activeSession.portal then
				return
			end
			if payload.state and payload.state ~= "PopupOpen" then
				activeSession.close()
			end
		end)
	end)

	print("[PartyPopup] 초기화 완료")
end

return PartyPopup
