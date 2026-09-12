--[[
	펫은 Anchored 파츠라 서버가 매 Heartbeat PivotTo로 위치를 갱신해도, 클라이언트는
	Unanchored 파츠처럼 엔진이 자동으로 보간/외삽해주지 않고 리플리케이션된 CFrame으로
	그대로 스냅한다. 그 결과 이동 중 튀는(떨리는) 것처럼 보인다.

	이 모듈은 각 펫 모델의 GetPivot()을 매 프레임 관찰해, "우리가 직전 프레임에 렌더링용으로
	쓴 값과 달라졌다면" 그것을 서버로부터 온 새 값으로 간주해 타임스탬프와 함께 버퍼에 쌓고,
	실제 렌더링은 그보다 RENDER_DELAY_SEC만큼 과거 시점을 두 샘플 사이에서 보간해 그린다.
	(엔티티 보간/스냅샷 인터폴레이션 기법)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local PetRenderSmoothing = {}

local PET_NAME_PREFIX = "Pet_"
local RENDER_DELAY_SEC = 0.1 -- 이 값만큼 과거 시점을 보간해 그려서, 샘플 도착 간격이 들쭉날쭉해도 매끄럽게 이어붙인다
local SAMPLE_RETENTION_SEC = RENDER_DELAY_SEC + 0.5 -- 이보다 오래된 샘플은 버림
local POSITION_EPSILON = 1e-4

type Sample = { cframe: CFrame, time: number }

type Tracked = {
	model: Model,
	samples: { Sample },
	lastRendered: CFrame,
}

local clockStart = os.clock()
local function now(): number
	return os.clock() - clockStart
end

local tracked: { [Model]: Tracked } = {}

local function isPetModel(inst: Instance): boolean
	return inst:IsA("Model") and inst.Name:sub(1, #PET_NAME_PREFIX) == PET_NAME_PREFIX
end

local function untrackModel(model: Model)
	tracked[model] = nil
end

local function trackModel(model: Model)
	if tracked[model] then
		return
	end

	local initialCFrame = model:GetPivot()
	tracked[model] = {
		model = model,
		samples = { { cframe = initialCFrame, time = now() } },
		lastRendered = initialCFrame,
	}

	model.Destroying:Connect(function()
		untrackModel(model)
	end)
end

local function scanCharacterPets(character: Model)
	for _, child in character:GetChildren() do
		if isPetModel(child) then
			trackModel(child :: Model)
		end
	end
	character.ChildAdded:Connect(function(child)
		if isPetModel(child) then
			trackModel(child :: Model)
		end
	end)
end

local function hookPlayer(player: Player)
	player.CharacterAdded:Connect(scanCharacterPets)
	if player.Character then
		scanCharacterPets(player.Character)
	end
end

--- 두 CFrame이 (부동소수점 오차 범위 내에서) 사실상 같은 값인지: 우리가 직전에 렌더링용으로
--- 세팅한 값 그대로라 서버로부터 새 갱신이 없었다는 뜻이면 true.
local function isSameCFrame(a: CFrame, b: CFrame): boolean
	return (a.Position - b.Position).Magnitude < POSITION_EPSILON
		and (a.LookVector - b.LookVector).Magnitude < POSITION_EPSILON
end

local function interpolateSamples(samples: { Sample }, renderTime: number): CFrame
	local count = #samples
	if renderTime <= samples[1].time then
		return samples[1].cframe
	end
	if renderTime >= samples[count].time then
		return samples[count].cframe
	end
	for i = 1, count - 1 do
		local a, b = samples[i], samples[i + 1]
		if renderTime >= a.time and renderTime <= b.time then
			local span = b.time - a.time
			local alpha = if span > 1e-5 then (renderTime - a.time) / span else 1
			return a.cframe:Lerp(b.cframe, alpha)
		end
	end
	return samples[count].cframe
end

local function step()
	local currentTime = now()
	local renderTime = currentTime - RENDER_DELAY_SEC

	for model, entry in tracked do
		if not model.Parent then
			untrackModel(model)
			continue
		end

		local actualPivot = model:GetPivot()
		if not isSameCFrame(actualPivot, entry.lastRendered) then
			-- 우리가 마지막으로 그린 값과 다르면, 그 사이에 서버발 갱신이 새로 반영된 것
			table.insert(entry.samples, { cframe = actualPivot, time = currentTime })
		end

		local samples = entry.samples
		local cutoff = currentTime - SAMPLE_RETENTION_SEC
		while #samples > 2 and samples[2].time < cutoff do
			table.remove(samples, 1)
		end

		local renderCFrame = interpolateSamples(samples, renderTime)
		if not isSameCFrame(renderCFrame, entry.lastRendered) then
			model:PivotTo(renderCFrame)
			entry.lastRendered = renderCFrame
		end
	end
end

function PetRenderSmoothing.init()
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
	Players.PlayerAdded:Connect(hookPlayer)

	RunService.RenderStepped:Connect(step)
end

return PetRenderSmoothing
