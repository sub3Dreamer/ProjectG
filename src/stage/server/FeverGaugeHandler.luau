--[[
	스테이지 피버 게이지 (서버 권한): 파괴 시 증가, Fever ON 시 1.0 소모 후 0으로.
	클라이언트는 FeverGaugeSyncEvent로 0~1 동기화.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameSettings = require(Shared.Config.GameSettings)

local FeverGaugeHandler = {}

local gaugeByUserId: { [number]: number } = {}
local syncEvent: RemoteEvent? = nil
local autoChargeTasksByUserId: { [number]: thread } = {}

local function clamp01(n: number): number
	return math.clamp(n, 0, 1)
end

function FeverGaugeHandler.init(remoteEvent: RemoteEvent)
	syncEvent = remoteEvent
end

local function fireSync(player: Player, value: number)
	if syncEvent then
		syncEvent:FireClient(player, value)
	end
end

local function cancelAutoCharge(player: Player)
	local uid = player.UserId
	local existing = autoChargeTasksByUserId[uid]
	if existing then
		task.cancel(existing)
		autoChargeTasksByUserId[uid] = nil
	end
end

function FeverGaugeHandler.onPlayerAdded(player: Player)
	gaugeByUserId[player.UserId] = 0
	fireSync(player, 0)
end

function FeverGaugeHandler.onPlayerRemoving(player: Player)
	gaugeByUserId[player.UserId] = nil
	cancelAutoCharge(player)
end

function FeverGaugeHandler.getGauge(player: Player): number
	return gaugeByUserId[player.UserId] or 0
end

--- 게이지를 절대값(0~1)으로 지정 — FeverGaugeStageStart 옵션 등 스테이지 시작 시 초기치 세팅용
function FeverGaugeHandler.setGauge(player: Player, value: number)
	local v = clamp01(value)
	gaugeByUserId[player.UserId] = v
	fireSync(player, v)
end

--- percent(0~100)만큼 게이지 증가 — FeverGaugeAutoCharge 등 % 단위 증가분 공용 처리
function FeverGaugeHandler.addPercent(player: Player, percent: number)
	if typeof(percent) ~= "number" or percent <= 0 then
		return
	end
	local ch = player.Character
	if ch and ch:GetAttribute("FeverMode") == true then
		return
	end
	local uid = player.UserId
	gaugeByUserId[uid] = clamp01((gaugeByUserId[uid] or 0) + percent / 100)
	fireSync(player, gaugeByUserId[uid])
end

--- 데미지 가능 오브젝트 1개 파괴 시 호출
function FeverGaugeHandler.addDestroyProgress(player: Player)
	local ch = player.Character
	if ch and ch:GetAttribute("FeverMode") == true then
		return
	end

	local uid = player.UserId
	local d = GameSettings.Combat.FeverGaugePerDestroy
	if typeof(d) ~= "number" or d <= 0 then
		d = 0.03
	end

	local bonusPercent = player:GetAttribute("FeverGaugeGainBonusPercent")
	if typeof(bonusPercent) == "number" and bonusPercent > 0 then
		d = d * (1 + bonusPercent / 100)
	end

	gaugeByUserId[uid] = clamp01((gaugeByUserId[uid] or 0) + d)
	fireSync(player, gaugeByUserId[uid])
end

--- Fever를 켤 때(게이지 1.0 소모) 호출 — toggle 성공 직전
function FeverGaugeHandler.resetAfterFeverActivation(player: Player)
	gaugeByUserId[player.UserId] = 0
	fireSync(player, 0)
end

--[[
	FeverGaugeAutoCharge 옵션(intervalSec마다 percent%) 주기적 자동 충전 시작.
	intervalSec/percent 둘 다 0보다 커야 실제로 타이머가 시작됨(옵션 미보유 시 아무 것도 안 함).
	기존 타이머가 있으면 먼저 취소 후 새로 시작 — 스테이지 재시작 등 재진입에도 안전.
]]
function FeverGaugeHandler.startAutoCharge(player: Player, intervalSec: number, percent: number)
	cancelAutoCharge(player)
	if typeof(intervalSec) ~= "number" or intervalSec <= 0 then
		return
	end
	if typeof(percent) ~= "number" or percent <= 0 then
		return
	end

	local uid = player.UserId
	autoChargeTasksByUserId[uid] = task.spawn(function()
		while true do
			task.wait(intervalSec)
			if not player.Parent then
				break
			end
			FeverGaugeHandler.addPercent(player, percent)
		end
	end)
end

--- 스테이지 종료/실패 시 정리(누수 방지)
function FeverGaugeHandler.stopAutoCharge(player: Player)
	cancelAutoCharge(player)
end

return FeverGaugeHandler
