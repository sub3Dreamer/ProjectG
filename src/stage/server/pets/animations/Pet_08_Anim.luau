--[[
	"Mystic Flower" 펫(공중펫)의 Idle/Move 모션. PetManager가 매 Heartbeat마다
	모든 펫 공용 클록(elapsed)과 펫별 스크래치 테이블(ctx)을 넘겨 호출한다.

	이 펫은 다리/발 조인트가 없어(FOOT_JOINT_NAMES 불일치) PetManager가 자동으로
	GetBoundingBox() fallback을 타서 "바운딩박스 바닥이 지면에 닿는" 높이로 배치한다.
	그 위에 hoverHeightStuds만큼 매 프레임 추가로 띄워서 완전히 공중에 뜬 것처럼 보이게 한다.

	Motor6D 조인트 이름(Studio 리그 원본 이름 그대로):
	  Body 자식: CrystalMotor → Crystal(머리 위 크리스탈), FlowerPetalsMotor → FlowerPetals(꽃잎),
	    LeftAccs1/2/3Motor → LeftAccs1/2/3(왼쪽 잎/장식), RightAccs1/2/3Motor → RightAccs1/2/3(오른쪽),
	    LeftWingMotor → LeftWing, RightWingMotor → RightWing
	  LeftWing 자식: LeftWingTipMotor → LeftWingTip (날개 끝, 몸통쪽 날개보다 살짝 늦게 따라가는 파동)
	  RightWing 자식: RightWingTipMotor → RightWingTip
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MotorJointAnimator = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utils"):WaitForChild("MotorJointAnimator"))

local Pet_08_Anim = {}

-- 공중펫 고정 오프셋: PetManager가 배치하는 "바운딩박스 바닥이 지면에 닿는" 높이에 매 프레임
-- 이만큼 더해 플레이어 어깨 높이 근처에서 떠 있도록 한다. 펫 자체 Scale(currentScale)에 비례시켜야
-- 레벨업으로 펫이 커져도 상대적 높이가 유지된다. 실제 게임 내 비주얼 보고 조정 필요.
local hoverHeightStuds = 10

local idleCycleDuration = 3.6
local idleBodyBob = 0.4
local idleWingSwing = math.rad(8) -- 날지 않고 떠 있을 때의 미세한 "숨쉬듯" 날개 접었다 폄
local idleWingTipSwing = math.rad(6)
local idlePetalSway = math.rad(6) -- 꽃잎이 살짝 벌어졌다 오므라드는 느낌
local idleAccsSway = math.rad(10) -- 잎/장식이 바람에 살랑이는 폭
local idleAccsPhaseStep = 0.18 -- Accs1→2→3로 갈수록 위상이 이만큼씩 늦어져 파도처럼 보임

local flyCycleDuration = 0.5 -- 날갯짓 주기. Idle보다 훨씬 빠르게
local flyBodyBob = 1.2 -- 날갯짓에 맞춰 위아래로 살짝 출렁이는 비행 특유의 상하 요동
local flyForwardTilt = math.rad(14) -- 비행 중 몸을 앞으로 기울이는 고정 각도
local flyWingSwing = math.rad(42) -- 날개(몸통쪽)가 위아래로 크게 펄럭이는 폭
local flyWingTipSwing = math.rad(32) -- 날개 끝은 몸통쪽 날개보다 살짝 늦게 따라가 파동처럼 보이게 함
local flyWingTipPhaseDelay = flyCycleDuration * 0.15
local flyPetalSway = math.rad(10)
local flyAccsSway = math.rad(18)

local crystalSpinSpeed = math.rad(70) -- 상태와 무관하게 항상 천천히 계속 도는 크리스탈 회전 속도(초당 라디안)
local crystalBobCycleDuration = 2.2 -- 몸통 bob과 별개 위상으로 살짝 떠 있는 크리스탈 자체의 부유감
local crystalBobAmplitude = 0.25

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

--- 몸통쪽 날개(Wing)를 메인 날갯짓으로, 날개 끝(WingTip)을 살짝 늦게 따라가는 보조 파동으로 삼아
--- 좌우 대칭으로 위아래(로컬 Z축 회전 → 옆으로 뻗은 날개가 위아래로 펄럭이도록)로 젓는다.
--- 좌우 날개 지오메트리가 서로 거울상이라 부호를 반대로 줘야 시각적으로 같은 방향으로 움직인다.
local function animateWings(
	joints: { [string]: Motor6D },
	wingSwing: number,
	wingTipSwing: number,
	wingTipPhaseDelay: number,
	cycleDuration: number,
	elapsed: number
)
	local wingRaw = osc(elapsed, 0, cycleDuration)
	local tipRaw = osc(elapsed, wingTipPhaseDelay, cycleDuration)

	MotorJointAnimator.applyJointTransform(joints.LeftWingMotor, CFrame.Angles(0, 0, wingSwing * wingRaw))
	MotorJointAnimator.applyJointTransform(joints.RightWingMotor, CFrame.Angles(0, 0, -wingSwing * wingRaw))
	MotorJointAnimator.applyJointTransform(joints.LeftWingTipMotor, CFrame.Angles(0, 0, wingTipSwing * tipRaw))
	MotorJointAnimator.applyJointTransform(joints.RightWingTipMotor, CFrame.Angles(0, 0, -wingTipSwing * tipRaw))
end

local function animatePetals(joints: { [string]: Motor6D }, swingAngle: number, raw: number)
	MotorJointAnimator.applyJointTransform(joints.FlowerPetalsMotor, CFrame.Angles(swingAngle * raw, 0, 0))
end

--- 왼쪽/오른쪽 각 3개의 잎(Accs1~3)을 인덱스가 커질수록 위상을 늦춰 바람에 물결치듯 흔든다.
--- 좌우는 서로 반대 부호로 벌어졌다 오므라들게 해 대칭을 이룬다.
local function animateAccs(joints: { [string]: Motor6D }, swingAngle: number, phaseStep: number, cycleDuration: number, elapsed: number)
	for i = 1, 3 do
		local raw = osc(elapsed, phaseStep * (i - 1), cycleDuration)
		MotorJointAnimator.applyJointTransform(joints["LeftAccs" .. i .. "Motor"], CFrame.Angles(0, 0, swingAngle * raw))
		MotorJointAnimator.applyJointTransform(joints["RightAccs" .. i .. "Motor"], CFrame.Angles(0, 0, -swingAngle * raw))
	end
end

--- 상태(Idle/Move/Attack)와 무관하게 항상 천천히 계속 도는 크리스탈. 몸통 bob과는 별개 위상으로
--- 살짝 떠 있는 부유감을 더한다.
local function animateCrystal(joints: { [string]: Motor6D }, elapsed: number, sc: number)
	local bobRaw = osc(elapsed, 0, crystalBobCycleDuration)
	MotorJointAnimator.applyJointTransform(
		joints.CrystalMotor,
		CFrame.new(0, crystalBobAmplitude * sc * bobRaw, 0) * CFrame.Angles(0, elapsed * crystalSpinSpeed, 0)
	)
end

function Pet_08_Anim.Idle(pet: Model, joints: { [string]: Motor6D }, elapsed: number, _ctx: { [string]: any }, scale: number?)
	local s = osc(elapsed, 0, idleCycleDuration)
	local lift = (s + 1) / 2 -- -1~1을 0~1로 이동: 멈추는 구간 없이 계속 오르내리되 기준보다 아래로는 안 내려감
	local sc = safeScale(scale)

	local bodyPart = pet:FindFirstChild("Body")
	if bodyPart and bodyPart:IsA("BasePart") then
		bodyPart.CFrame = bodyPart.CFrame * CFrame.new(0, hoverHeightStuds * sc + idleBodyBob * sc * lift, 0)
	end

	animateWings(joints, idleWingSwing, idleWingTipSwing, idleCycleDuration * 0.15, idleCycleDuration, elapsed)
	animatePetals(joints, idlePetalSway, s)
	animateAccs(joints, idleAccsSway, idleAccsPhaseStep, idleCycleDuration, elapsed)
	animateCrystal(joints, elapsed, sc)
end

--- 미스틱 플라워가 날아서 이동하는 모션. 실제 이동 자체는 PetManager(updateAllPets의
--- smoothDampTargetPosition)가 담당하므로, 여기서는 그 위에 얹히는 장식(날갯짓, 비행 특유의
--- 상하 bob, 전방 기울임, 꽃잎/잎 흔들림)만 담당한다.
function Pet_08_Anim.Move(pet: Model, joints: { [string]: Motor6D }, elapsed: number, _ctx: { [string]: any }, scale: number?)
	local raw = osc(elapsed, 0, flyCycleDuration)
	local sc = safeScale(scale)

	local bodyPart = pet:FindFirstChild("Body")
	if bodyPart and bodyPart:IsA("BasePart") then
		bodyPart.CFrame = bodyPart.CFrame
			* CFrame.new(0, hoverHeightStuds * sc + flyBodyBob * sc * raw, 0)
			* CFrame.Angles(-flyForwardTilt, 0, 0)
	end

	animateWings(joints, flyWingSwing, flyWingTipSwing, flyWingTipPhaseDelay, flyCycleDuration, elapsed)
	animatePetals(joints, flyPetalSway, raw)
	animateAccs(joints, flyAccsSway, idleAccsPhaseStep, flyCycleDuration, elapsed)
	animateCrystal(joints, elapsed, sc)
end

return Pet_08_Anim
