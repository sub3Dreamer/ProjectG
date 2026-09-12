--[[
	"Nerdy Dragon" 펫(공중펫)의 Idle/Move 모션. PetManager가 매 Heartbeat마다
	모든 펫 공용 클록(elapsed)과 펫별 스크래치 테이블(ctx)을 넘겨 호출한다.

	이 펫은 다른 공중펫(Pet_06/07/08/10)과 달리 발 조인트 이름이 지상펫과 동일한
	FootBLJoint/FootBRJoint/FootFLJoint/FootFRJoint라서, PetManager는 GetBoundingBox() fallback이
	아니라 실제 발 파츠 기준으로 "지면에 닿는" 높이를 계산한다(computePetFootBottomY). 다만 결과는
	동일하게 그 위에 hoverHeightStuds만큼 매 프레임 추가로 띄워서 공중에 뜬 것처럼 보이게 한다.

	Motor6D 조인트 이름(Studio 리그 원본 이름 그대로):
	  Body 자식: FootBLJoint/FootBRJoint/FootFLJoint/FootFRJoint → 다리(Foot) 파츠,
	    GlassesMotor → Glasses(안경), HornsMotor → Horns(뿔), LeftWingMotor → LeftWing, RightWingMotor → RightWing
	  LeftWing 자식: LeftWingTipMotor → LeftWingTip (날개 끝. Wing과 한 몸처럼 붙어있는 구조라 같은 각도·타이밍으로 함께 움직임)
	  RightWing 자식: RightWingTipMotor → RightWingTip
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MotorJointAnimator = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utils"):WaitForChild("MotorJointAnimator"))

local Pet_09_Anim = {}

-- 공중펫 고정 오프셋: PetManager가 배치하는 "발이 지면에 닿는" 높이에 매 프레임 이만큼 더해
-- 플레이어 어깨 높이 근처에서 떠 있도록 한다. 펫 자체 Scale(currentScale)에 비례시켜야
-- 레벨업으로 펫이 커져도 상대적 높이가 유지된다. 실제 게임 내 비주얼 보고 조정 필요.
local hoverHeightStuds = 12

local idleCycleDuration = 3.0
local idleBodyBob = 0.4
local idleWingSwing = math.rad(8) -- 날지 않고 떠 있을 때의 미세한 "숨쉬듯" 날개 접었다 폄
local idleHornSway = math.rad(5)
local idleLegSway = math.rad(6)
local idleGlassesNudge = 0.03 -- 안경을 살짝 치켜올렸다 내리는 너드 특유의 잔동작

local flyCycleDuration = 0.5 -- 날갯짓 주기. Idle보다 훨씬 빠르게
local flyBodyBob = 1.2 -- 날갯짓에 맞춰 위아래로 살짝 출렁이는 비행 특유의 상하 요동
local flyForwardTilt = math.rad(18) -- 비행 중 몸을 앞으로 기울이는 고정 각도
local flyWingSwing = math.rad(45) -- 날개가 위아래로 크게 펄럭이는 폭 (WingTip도 동일하게 함께 움직임)
local flyHornSway = math.rad(8)
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

--- Wing과 WingTip은 한 몸처럼 붙어있는 구조라, 위상 지연이나 별도 각도 없이 완전히 같은
--- 각도·타이밍으로 함께 움직여야 한다. 좌우 대칭으로 위아래(로컬 Z축 회전 → 옆으로 뻗은 날개가
--- 위아래로 펄럭이도록)로 젓는다. 좌우 날개 지오메트리가 서로 거울상이라 부호를 반대로 줘야
--- 시각적으로 같은 방향으로 움직인다.
local function animateWings(joints: { [string]: Motor6D }, wingSwing: number, cycleDuration: number, elapsed: number)
	local wingRaw = osc(elapsed, 0, cycleDuration)

	MotorJointAnimator.applyJointTransform(joints.LeftWingMotor, CFrame.Angles(0, 0, wingSwing * wingRaw))
	MotorJointAnimator.applyJointTransform(joints.RightWingMotor, CFrame.Angles(0, 0, -wingSwing * wingRaw))
	MotorJointAnimator.applyJointTransform(joints.LeftWingTipMotor, CFrame.Angles(0, 0, wingSwing * wingRaw))
	MotorJointAnimator.applyJointTransform(joints.RightWingTipMotor, CFrame.Angles(0, 0, -wingSwing * wingRaw))
end

local function animateHorns(joints: { [string]: Motor6D }, swingAngle: number, raw: number)
	MotorJointAnimator.applyJointTransform(joints.HornsMotor, CFrame.Angles(swingAngle * raw, 0, 0))
end

--- 다리(Foot) 조인트: tuckAngle만큼 몸 쪽으로 접어두고, 그 위에 raw에 비례한 흔들림을 얹는다.
local function animateLegs(joints: { [string]: Motor6D }, tuckAngle: number, swayAngle: number, raw: number)
	MotorJointAnimator.applyJointTransform(joints.FootFLJoint, CFrame.Angles(tuckAngle + swayAngle * raw, 0, 0))
	MotorJointAnimator.applyJointTransform(joints.FootFRJoint, CFrame.Angles(tuckAngle + swayAngle * raw, 0, 0))
	MotorJointAnimator.applyJointTransform(joints.FootBLJoint, CFrame.Angles(tuckAngle - swayAngle * raw, 0, 0))
	MotorJointAnimator.applyJointTransform(joints.FootBRJoint, CFrame.Angles(tuckAngle - swayAngle * raw, 0, 0))
end

function Pet_09_Anim.Idle(pet: Model, joints: { [string]: Motor6D }, elapsed: number, _ctx: { [string]: any }, scale: number?)
	local s = osc(elapsed, 0, idleCycleDuration)
	local lift = (s + 1) / 2 -- -1~1을 0~1로 이동: 멈추는 구간 없이 계속 오르내리되 기준보다 아래로는 안 내려감
	local sc = safeScale(scale)

	local bodyPart = pet:FindFirstChild("Body")
	if bodyPart and bodyPart:IsA("BasePart") then
		bodyPart.CFrame = bodyPart.CFrame * CFrame.new(0, hoverHeightStuds * sc + idleBodyBob * sc * lift, 0)
	end

	animateWings(joints, idleWingSwing, idleCycleDuration, elapsed)
	animateHorns(joints, idleHornSway, s)
	animateLegs(joints, 0, idleLegSway, s)
	MotorJointAnimator.applyJointTransform(joints.GlassesMotor, CFrame.new(0, idleGlassesNudge * sc * lift, 0))
end

--- 너디 드래곤이 날아서 이동하는 모션. 실제 이동 자체는 PetManager(updateAllPets의
--- smoothDampTargetPosition)가 담당하므로, 여기서는 그 위에 얹히는 장식(날갯짓, 비행 특유의
--- 상하 bob, 전방 기울임, 다리 접기)만 담당한다.
function Pet_09_Anim.Move(pet: Model, joints: { [string]: Motor6D }, elapsed: number, _ctx: { [string]: any }, scale: number?)
	local raw = osc(elapsed, 0, flyCycleDuration)
	local sc = safeScale(scale)

	local bodyPart = pet:FindFirstChild("Body")
	if bodyPart and bodyPart:IsA("BasePart") then
		bodyPart.CFrame = bodyPart.CFrame
			* CFrame.new(0, hoverHeightStuds * sc + flyBodyBob * sc * raw, 0)
			* CFrame.Angles(-flyForwardTilt, 0, 0)
	end

	animateWings(joints, flyWingSwing, flyCycleDuration, elapsed)
	animateHorns(joints, flyHornSway, raw)
	animateLegs(joints, flyLegTuck, flyLegSway, raw)
end

return Pet_09_Anim
