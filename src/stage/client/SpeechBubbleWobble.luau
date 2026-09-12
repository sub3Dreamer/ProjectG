--[[
	SpeechBubbleManager(서버)가 건물마다 Clone해 배치하는 SpeechBubbleGui(BillboardGui)의
	BubbleFrame을 좌우로 흔든다.

	원래는 템플릿 안에 내장된 LocalScript(BalloonMove)로 처리하려 했으나, 서버가 런타임에
	Clone해서 Workspace에 Parent시키는 BillboardGui 하위의 내장 LocalScript가 실행되지 않는
	현상이 있어(ClassName/Disabled/템플릿 중복/Output 필터 모두 정상 확인했음에도 진단용 print가
	단 한 번도 찍히지 않음), 대신 이미 정상 동작 중인 이 클라이언트 스크립트 체계에서 직접 흔든다.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SpeechBubbleWobble = {}

local BUBBLE_NAME = "SpeechBubbleGui"
local FRAME_NAME = "BubbleFrame"
local AMPLITUDE_DEGREES = 6 -- 좌우로 흔들리는 최대 각도
local PERIOD_SECONDS = 3 -- 왕복 1주기 시간(초)

type Tracked = {
	baseRotation: number,
	startTime: number,
}

local tracked: { [Frame]: Tracked } = {}
local initialized = false

local function trackBubble(bubbleGui: Instance)
	if not bubbleGui:IsA("BillboardGui") then
		return
	end
	local frameInst = bubbleGui:FindFirstChild(FRAME_NAME)
	if not (frameInst and frameInst:IsA("Frame")) then
		return
	end
	local frame = frameInst :: Frame
	if tracked[frame] then
		return
	end

	tracked[frame] = {
		baseRotation = frame.Rotation,
		startTime = os.clock(),
	}

	frame.Destroying:Connect(function()
		tracked[frame] = nil
	end)
end

local function scanExisting()
	for _, inst in Workspace:GetDescendants() do
		if inst.Name == BUBBLE_NAME then
			trackBubble(inst)
		end
	end
end

function SpeechBubbleWobble.init()
	if initialized then
		return
	end
	initialized = true

	scanExisting()

	Workspace.DescendantAdded:Connect(function(inst: Instance)
		if inst.Name == BUBBLE_NAME then
			trackBubble(inst)
		end
	end)

	RunService.RenderStepped:Connect(function()
		for frame, entry in tracked do
			if not frame.Parent then
				tracked[frame] = nil
				continue
			end
			local elapsed = os.clock() - entry.startTime
			local angle = math.sin((elapsed / PERIOD_SECONDS) * math.pi * 2) * AMPLITUDE_DEGREES
			frame.Rotation = entry.baseRotation + angle
		end
	end)

	print("[SpeechBubbleWobble] 초기화 완료")
end

return SpeechBubbleWobble
