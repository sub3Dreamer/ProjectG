--[[
	SpawnLocation의 EnemyModelName 속성값 = ReplicatedStorage.Enemies 안 템플릿 Model 이름.
	아래 setups에 같은 문자열 키로 서버 setup만 등록하면 된다.
]]

local BlackSoldier = require(script.Parent.blacksoldier.BlackSoldier)

local EnemySetup = {}

EnemySetup.AttributeName = "EnemyModelName"
--- 스폰된 적 모델에 붙임. NPCAI 등에서 동일 이름으로 읽는다(순환 require 방지로 문자열 맞출 것).
EnemySetup.EnemyNpcAttributeName = "EnemyNpc"

export type SetupFn = (model: Model) -> ()

local setups: { [string]: SetupFn } = {
	BlackSoldier = function(model: Model)
		BlackSoldier.setup(model)
	end,
}

local CORPSE_REMAIN_SEC = 3
local DEATH_POLL_SEC = 0.2
local HUMANOID_WAIT_SEC = 15

local function findHumanoidOnEnemy(model: Model): Humanoid?
	local h = model:FindFirstChildOfClass("Humanoid")
	if h and h:IsA("Humanoid") then
		return h
	end
	return model:FindFirstChildWhichIsA("Humanoid", true)
end

local function waitForHumanoid(model: Model): Humanoid?
	local t0 = os.clock()
	local hum = findHumanoidOnEnemy(model)
	while not hum and model.Parent and os.clock() - t0 < HUMANOID_WAIT_SEC do
		task.wait(0.05)
		hum = findHumanoidOnEnemy(model)
	end
	return hum
end

local function scheduleDestroyAfterDeath(model: Model)
	local hum = waitForHumanoid(model)
	if not hum or not hum:IsA("Humanoid") then
		warn("[EnemySetup] 사망 감시 불가 — Humanoid 없음(직계·하위 모두 검색):", model:GetFullName())
		return
	end

	print(
		"[EnemySetup] 사망 감시 연결:",
		model.Name,
		"| Humanoid=",
		hum:GetFullName(),
		"| MaxHealth=",
		hum.MaxHealth,
		"| Health=",
		hum.Health
	)

	local armed = false
	local dconn: RBXScriptConnection?
	local hpConn: RBXScriptConnection?
	local hcConn: RBXScriptConnection?
	local stConn: RBXScriptConnection?

	local function disconnectAll()
		if dconn then
			dconn:Disconnect()
			dconn = nil
		end
		if hpConn then
			hpConn:Disconnect()
			hpConn = nil
		end
		if hcConn then
			hcConn:Disconnect()
			hcConn = nil
		end
		if stConn then
			stConn:Disconnect()
			stConn = nil
		end
	end

	-- Health가 0 이하(엔진은 종종 아주 작은 양수로 클램프)이거나 Dead 상태면 사망으로 본다.
	local function isDeadish(): boolean
		local okH, hp = pcall(function()
			return hum.Health
		end)
		if okH and typeof(hp) == "number" and hp == hp and hp <= 1e-4 then
			return true
		end
		local ok, st = pcall(function()
			return hum:GetState()
		end)
		if ok and st == Enum.HumanoidStateType.Dead then
			return true
		end
		return false
	end

	local function armDestroyCorpse()
		if armed then
			return
		end
		armed = true
		disconnectAll()
		local stateStr = "?"
		local okSt, st = pcall(function()
			return hum:GetState()
		end)
		if okSt then
			stateStr = tostring(st.Name)
		end
		local hpStr = "?"
		local maxStr = "?"
		local okHp, hpVal = pcall(function()
			return hum.Health
		end)
		if okHp then
			hpStr = tostring(hpVal)
		end
		local okMax, maxVal = pcall(function()
			return hum.MaxHealth
		end)
		if okMax then
			maxStr = tostring(maxVal)
		end
		print(
			"[EnemySetup] 사망 감시: 사망 확정 →",
			CORPSE_REMAIN_SEC,
			"초 후 Destroy | model=",
			model.Name,
			"| Health=",
			hpStr,
			"| MaxHealth=",
			maxStr,
			"| HumanoidState=",
			stateStr
		)
		task.delay(CORPSE_REMAIN_SEC, function()
			if model.Parent then
				print("[EnemySetup] 사망 후 제거 실행 Destroy:", model.Name)
				pcall(function()
					model:Destroy()
				end)
			else
				print("[EnemySetup] 사망 후 제거 스킵(이미 Parent 없음):", model.Name)
			end
		end)
	end

	dconn = hum.Died:Connect(armDestroyCorpse)

	hcConn = hum.HealthChanged:Connect(function()
		if hum.Health <= 1e-4 then
			armDestroyCorpse()
		end
	end)

	hpConn = hum:GetPropertyChangedSignal("Health"):Connect(function()
		if hum.Health <= 1e-4 then
			armDestroyCorpse()
		end
	end)

	stConn = hum.StateChanged:Connect(function(_old: Enum.HumanoidStateType, new: Enum.HumanoidStateType)
		if new == Enum.HumanoidStateType.Dead then
			armDestroyCorpse()
		end
	end)

	if isDeadish() then
		armDestroyCorpse()
	end

	-- hum.Parent가 사망 직후 nil이 되는 경우가 있어 model.Parent만 본다(안 그러면 폴링이 먼저 빠져나가 사망 로그가 안 뜰 수 있음).
	task.spawn(function()
		while not armed and model.Parent do
			if isDeadish() then
				armDestroyCorpse()
				break
			end
			task.wait(DEATH_POLL_SEC)
		end
	end)
end

function EnemySetup.trim(raw: string): string
	return raw:gsub("^%s+", ""):gsub("%s+$", "")
end

function EnemySetup.isRegistered(code: string): boolean
	return setups[code] ~= nil
end

--- 등록된 코드면 setup 호출 후 true, 아니면 경고 후 false
--- 스폰 직후 EnemySpawnLocations.spawnOneAt → 여기서 타입별 setup + 사망 감시 연결.
function EnemySetup.setup(code: string, model: Model): boolean
	print("[EnemySetup] setup 호출:", code, "|", model:GetFullName())
	local fn = setups[code]
	if fn then
		model:SetAttribute(EnemySetup.EnemyNpcAttributeName, true)
		-- NPCAI 등이 Humanoid를 건드리기 전에 사망 시그널을 먼저 건다.
		scheduleDestroyAfterDeath(model)
		fn(model)
		return true
	end
	warn("[EnemySetup] 등록되지 않은 코드 — 사망 감시·AI 없음:", code, "|", model:GetFullName())
	return false
end

return EnemySetup
