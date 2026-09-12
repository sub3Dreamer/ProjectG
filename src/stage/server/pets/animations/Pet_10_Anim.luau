--[[
	"Parrot" 펫(공중펫)의 Idle/Move 모션. PetManager가 매 Heartbeat마다
	모든 펫 공용 클록(elapsed)과 펫별 스크래치 테이블(ctx)을 넘겨 호출한다.

	이 펫은 다리 조인트가 LeftFootJoint/RightFootJoint 2개뿐이라 지상펫의
	FOOT_JOINT_NAMES(FootFLJoint 등 4개)와 이름이 달라 PetManager는 자동으로
	GetBoundingBox() fallback을 타서 "바운딩박스 바닥이 지면에 닿는" 높이로 배치한다. 그 위에
	hoverHeightStuds만큼 매 프레임 추가로 띄워서 어깨 위에 앉아 나는 것처럼 보이게 한다.

	Motor6D 조인트 이름(Studio 리그 원본 이름 그대로):
	  Body 자식: BeakMotor → Beak(부리, 애니메이션 없음), InnerWingsMotor → InnerWings(안쪽 날개),
	    OuterWingsMotor → OuterWings(바깥쪽 날개), LeftFootJoint → LeftFoot, RightFootJoint → RightFoot,
	    LeftHornMotor → LeftHorn(볏), RightHornMotor → RightHorn
	  다른 공중펫(Pet_06/07/08/09)과 달리 날개가 좌우 별도 파츠가 아니라 Inner/Outer 2겹으로 겹쳐
	  하나씩만 있다. 이 둘은 사실상 날개 하나이므로 위상 지연 없이 완전히 같은 타이밍으로,
	  로컬 Y축 회전으로 한몸처럼 펄럭인다.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MotorJointAnimator = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utils"):WaitForChild("MotorJointAnimator"))

local Pet_10_Anim = {}

-- 공중펫 고정 오프셋: PetManager가 배치하는 "바운딩박스 바닥이 지면에 닿는" 높이에 매 프레임
-- 이만큼 더해 플레이어 어깨 높이 근처에서 떠 있도록 한다. 펫 자체 Scale(currentScale)에 비례시켜야
-- 레벨업으로 펫이 커져도 상대적 높이가 유지된다. 실제 게임 내 비주얼 보고 조정 필요.
local hoverHeightStuds = 8

local idleCycleDuration = 2.6
local idleBodyBob = 0.3
local idleWingSwing = math.rad(6) -- 날지 않고 앉아 있을 때의 미세한 "숨쉬듯" 날개 접었다 폄
local idleWingOuterSwing = math.rad(6)
local idleHornSway = math.rad(6)
local idleFootSway = math.rad(4) -- 나뭇가지를 움켜쥔 채 살짝 무게중심 바꾸는 느낌

local flyCycleDuration = 0.28 -- 앵무새 특유의 빠른 날갯짓 주기
local flyBodyBob = 0.9 -- 날갯짓에 맞춰 위아래로 살짝 출렁이는 비행 특유의 상하 요동
local flyForwardTilt = math.rad(20) -- 비행 중 몸을 앞으로 기울이는 고정 각도
local flyWingSwing = math.rad(20) -- 안쪽 날개가 위아래로 크게 펄럭이는 폭
local flyWingOuterSwing = math.rad(20)
local flyHornSway = math.rad(10)
local flyFootTuck = math.rad(30) -- 비행 중 발을 몸 쪽으로 당겨 접는 각도
local flyFootSway = math.rad(6)

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

--- InnerWings/OuterWings는 겹쳐진 날개 하나를 표현하는 두 파츠라, 위상 지연 없이 완전히 같은
--- 타이밍(raw)으로 같이 움직여야 한몸처럼 보인다. 좌우 각 파츠가 아니라 두 날개를 합친 파츠
--- 하나씩이라(다른 공중펫과 달리) 좌우 대칭 부호 반전도 필요 없다.
local function animateWings(joints: { [string]: Motor6D }, innerSwing: number, outerSwing: number, cycleDuration: number, elapsed: number)
	local raw = osc(elapsed, 0, cycleDuration)

	MotorJointAnimator.applyJointTransform(joints.InnerWingsMotor, CFrame.Angles(0, innerSwing * raw, 0))
	MotorJointAnimator.applyJointTransform(joints.OuterWingsMotor, CFrame.Angles(0, outerSwing * raw, 0))
end

--- Beak는 회전 연출이 없지만, Body.CFrame이 매 프레임 직접 갱신(bob/tilt)되는 반면 BeakMotor는
--- Motor6D 조인트라서 매 프레임 다시 적용해주지 않으면 Body와의 상대 위치가 갱신되지 않는다.
--- PivotTo가 모델 전체를 옮길 때 이 조인트가 그대로 방치되면 Body의 매 프레임 CFrame 변화가
--- 다음 프레임 PivotTo 델타 계산에 그대로 반영되어 Beak가 점점 아래로 밀려나며 어긋난다.
--- 그래서 회전 없이(identity) 매 프레임 재적용만 해서 Body에 고정시켜 둔다.
local function syncBeak(joints: { [string]: Motor6D })
	MotorJointAnimator.applyJointTransform(joints.BeakMotor, CFrame.new())
end

local function animateHorns(joints: { [string]: Motor6D }, swingAngle: number, raw: number)
	MotorJointAnimator.applyJointTransform(joints.LeftHornMotor, CFrame.Angles(0, 0, swingAngle * raw))
	MotorJointAnimator.applyJointTransform(joints.RightHornMotor, CFrame.Angles(0, 0, -swingAngle * raw))
end

--- 발(Foot) 조인트: tuckAngle만큼 몸 쪽으로 접어두고, 그 위에 raw에 비례한 흔들림을 얹는다.
local function animateFeet(joints: { [string]: Motor6D }, tuckAngle: number, swayAngle: number, raw: number)
	MotorJointAnimator.applyJointTransform(joints.LeftFootJoint, CFrame.Angles(tuckAngle + swayAngle * raw, 0, 0))
	MotorJointAnimator.applyJointTransform(joints.RightFootJoint, CFrame.Angles(tuckAngle - swayAngle * raw, 0, 0))
end

function Pet_10_Anim.Idle(pet: Model, joints: { [string]: Motor6D }, elapsed: number, _ctx: { [string]: any }, scale: number?)
	local s = osc(elapsed, 0, idleCycleDuration)
	local lift = (s + 1) / 2 -- -1~1을 0~1로 이동: 멈추는 구간 없이 계속 오르내리되 기준보다 아래로는 안 내려감
	local sc = safeScale(scale)

	local bodyPart = pet:FindFirstChild("Body")
	if bodyPart and bodyPart:IsA("BasePart") then
		bodyPart.CFrame = bodyPart.CFrame * CFrame.new(0, hoverHeightStuds * sc + idleBodyBob * sc * lift, 0)
	end

	animateWings(joints, idleWingSwing, idleWingOuterSwing, idleCycleDuration, elapsed)
	syncBeak(joints)
	animateHorns(joints, idleHornSway, s)
	animateFeet(joints, 0, idleFootSway, s)
end

--- 앵무새가 날아서 이동하는 모션. 실제 이동 자체는 PetManager(updateAllPets의
--- smoothDampTargetPosition)가 담당하므로, 여기서는 그 위에 얹히는 장식(날갯짓, 비행 특유의
--- 상하 bob, 전방 기울임, 발 접기)만 담당한다.
function Pet_10_Anim.Move(pet: Model, joints: { [string]: Motor6D }, elapsed: number, _ctx: { [string]: any }, scale: number?)
	local raw = osc(elapsed, 0, flyCycleDuration)
	local sc = safeScale(scale)

	local bodyPart = pet:FindFirstChild("Body")
	if bodyPart and bodyPart:IsA("BasePart") then
		bodyPart.CFrame = bodyPart.CFrame
			* CFrame.new(0, hoverHeightStuds * sc + flyBodyBob * sc * raw, 0)
			* CFrame.Angles(-flyForwardTilt, 0, 0)
	end

	animateWings(joints, flyWingSwing, flyWingOuterSwing, flyCycleDuration, elapsed)
	syncBeak(joints)
	animateHorns(joints, flyHornSway, raw)
	animateFeet(joints, flyFootTuck, flyFootSway, raw)
end

return Pet_10_Anim
