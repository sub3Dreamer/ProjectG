--[[
	"Axolotl" 펫(공중펫)의 Idle/Move 모션. PetManager가 매 Heartbeat마다
	모든 펫 공용 클록(elapsed)과 펫별 스크래치 테이블(ctx)을 넘겨 호출한다.

	지상펫(Pet_01~05)과 달리 발이 지면에 닿지 않고 플레이어 어깨 높이쯤에 떠 있어야 한다.
	이 펫의 Motor6D는 지상펫의 FootFLJoint 등과 이름이 달라 PetManager의 발 조인트 기준
	지면 오프셋 계산(FOOT_JOINT_NAMES)에 걸리지 않고 자동으로 GetBoundingBox() fallback을
	타므로, PetManager는 이 펫도 "바운딩박스 바닥이 지면에 닿는" 높이로 배치한다. 그 위에
	hoverHeightStuds만큼 매 프레임 추가로 띄워서 공중에 뜬 것처럼 보이게 한다.

	Motor6D 조인트 이름(Studio 리그 원본 이름 그대로, 공백 포함):
	  Left Front Hip / Right Front Hip / Left Back Hip / Right Back Hip → 다리(Foot) 파츠
	  Left Fin Joint / Right Fin Joint   → 앞쪽 날개 역할의 지느러미
	  Left Gill Joint / Right Gill Joint → 뒤쪽 날개 역할의 아가미(지느러미보다 살짝 늦게 따라가는 파동)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MotorJointAnimator = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utils"):WaitForChild("MotorJointAnimator"))

local Pet_06_Anim = {}

-- 공중펫 고정 오프셋: PetManager가 배치하는 "바운딩박스 바닥이 지면에 닿는" 높이에 매 프레임
-- 이만큼 더해 플레이어 어깨 높이 근처에서 떠 있도록 한다. 펫 자체 Scale(currentScale)에 비례시켜야
-- 레벨업으로 펫이 커져도 상대적 높이가 유지된다. 실제 게임 내 비주얼 보고 조정 필요.
local hoverHeightStuds = 12

local idleCycleDuration = 3.0
local idleBodyBob = 0.4
local idleFinSwing = math.rad(12)
local idleGillSwing = math.rad(10)
local idleLegSway = math.rad(6)

local flyCycleDuration = 0.5 -- 날갯짓 주기. Idle보다 훨씬 빠르게
local flyBodyBob = 1.2 -- 날갯짓에 맞춰 위아래로 살짝 출렁이는 비행 특유의 상하 요동
local flyForwardTilt = math.rad(18) -- 비행 중 몸을 앞으로 기울이는 고정 각도
local flyFinSwing = math.rad(40) -- 지느러미(앞날개)가 앞뒤로 크게 젓는 폭
local flyGillSwing = math.rad(32) -- 아가미(뒷날개)는 지느러미보다 살짝 늦게 따라가 파동처럼 보이게 함
local flyGillPhaseDelay = flyCycleDuration * 0.15
local flyLegTuck = math.rad(20) -- 비행 중 다리를 몸 쪽으로 당겨 접는 각도
local flyLegSway = math.rad(8)

local function osc(time: number, phaseOffset: number, duration: number): number
	local t = ((time + phaseOffset) % duration) / duration
	return math.sin(t * math.pi * 2)
end

--- PetManager가 매 프레임 entry.currentScale(펫의 현재 Model.Scale, 레벨업에 따라 커짐)을 넘겨준다.
--- 회전(각도) 값은 크기와 무관하게 그대로 두고, 스터드 단위 이동/거리 값에만 곱해야
--- 펫이 커져도(예: Scale 0.3 → 3) 애니메이션이 그 자리에서 미세하게 떠는 것처럼 보이지 않는다.
local function safeScale(scale: number?): number
	if typeof(scale) == "number" and scale == scale and scale > 0 then
		return scale
	end
	return 1
end

--- 지느러미(Fin)를 메인 날갯짓으로, 아가미(Gill)를 살짝 늦게 따라가는 보조 파동으로 삼아
--- 좌우 대칭으로 앞뒤(로컬 Y축 회전 → 옆으로 뻗은 날개 끝이 앞뒤로 호를 그리며 스윙)로 젓는다.
local function animateWings(
	joints: { [string]: Motor6D },
	finSwing: number,
	gillSwing: number,
	gillPhaseDelay: number,
	cycleDuration: number,
	elapsed: number
)
	local finRaw = osc(elapsed, 0, cycleDuration)
	local gillRaw = osc(elapsed, gillPhaseDelay, cycleDuration)

	MotorJointAnimator.applyJointTransform(joints["Left Fin Joint"], CFrame.Angles(0, finSwing * finRaw, 0))
	MotorJointAnimator.applyJointTransform(joints["Right Fin Joint"], CFrame.Angles(0, -finSwing * finRaw, 0))
	MotorJointAnimator.applyJointTransform(joints["Left Gill Joint"], CFrame.Angles(0, gillSwing * gillRaw, 0))
	MotorJointAnimator.applyJointTransform(joints["Right Gill Joint"], CFrame.Angles(0, -gillSwing * gillRaw, 0))
end

--- 다리(Hip) 조인트: tuckAngle만큼 몸 쪽으로 접어두고, 그 위에 raw에 비례한 흔들림을 얹는다.
local function animateLegs(joints: { [string]: Motor6D }, tuckAngle: number, swayAngle: number, raw: number)
	MotorJointAnimator.applyJointTransform(joints["Left Front Hip"], CFrame.Angles(tuckAngle + swayAngle * raw, 0, 0))
	MotorJointAnimator.applyJointTransform(joints["Right Front Hip"], CFrame.Angles(tuckAngle + swayAngle * raw, 0, 0))
	MotorJointAnimator.applyJointTransform(joints["Left Back Hip"], CFrame.Angles(tuckAngle - swayAngle * raw, 0, 0))
	MotorJointAnimator.applyJointTransform(joints["Right Back Hip"], CFrame.Angles(tuckAngle - swayAngle * raw, 0, 0))
end

function Pet_06_Anim.Idle(pet: Model, joints: { [string]: Motor6D }, elapsed: number, _ctx: { [string]: any }, scale: number?)
	local s = osc(elapsed, 0, idleCycleDuration)
	local lift = (s + 1) / 2 -- -1~1을 0~1로 이동: 멈추는 구간 없이 계속 오르내리되 기준보다 아래로는 안 내려감
	local sc = safeScale(scale)

	local bodyPart = pet:FindFirstChild("Body")
	if bodyPart and bodyPart:IsA("BasePart") then
		bodyPart.CFrame = bodyPart.CFrame * CFrame.new(0, hoverHeightStuds * sc + idleBodyBob * sc * lift, 0)
	end

	animateWings(joints, idleFinSwing, idleGillSwing, idleCycleDuration * 0.15, idleCycleDuration, elapsed)
	animateLegs(joints, 0, idleLegSway, s)
end

--- 새가 날아서 이동하는 모션. 실제 이동 자체는 PetManager(updateAllPets의 smoothDampTargetPosition)가
--- 담당하므로, 여기서는 그 위에 얹히는 장식(날갯짓, 비행 특유의 상하 bob, 전방 기울임, 다리 접기)만 담당한다.
function Pet_06_Anim.Move(pet: Model, joints: { [string]: Motor6D }, elapsed: number, _ctx: { [string]: any }, scale: number?)
	local raw = osc(elapsed, 0, flyCycleDuration)
	local sc = safeScale(scale)

	local bodyPart = pet:FindFirstChild("Body")
	if bodyPart and bodyPart:IsA("BasePart") then
		bodyPart.CFrame = bodyPart.CFrame
			* CFrame.new(0, hoverHeightStuds * sc + flyBodyBob * sc * raw, 0)
			* CFrame.Angles(-flyForwardTilt, 0, 0)
	end

	animateWings(joints, flyFinSwing, flyGillSwing, flyGillPhaseDelay, flyCycleDuration, elapsed)
	animateLegs(joints, flyLegTuck, flyLegSway, raw)
end

return Pet_06_Anim
