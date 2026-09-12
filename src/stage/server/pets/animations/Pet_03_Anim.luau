--[[
	"Cat" 펫의 Idle/Move 모션. PetManager가 매 Heartbeat마다
	모든 펫 공용 클록(elapsed)과 펫별 스크래치 테이블(ctx)을 넘겨 호출한다.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MotorJointAnimator = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Utils"):WaitForChild("MotorJointAnimator"))

local Pet_03_Anim = {}

local bodyBob = 0.5
local earWiggle = math.rad(5)
local snoutMove = 0.05
local tailSway = math.rad(20)
local footShift = 0.05

local cycleDuration = 3.0

local hopCycleDuration = 0.55 -- Idle보다 빠른 홉 주기. 짧고 통통 튀도록
local hopBodyBob = 5
local hopFootLift = 0.9
local hopLungeStuds = 0.6 -- 홉마다 몸이 앞으로(로컬 -Z) 쏠렸다 돌아오는 폭. 실제 비주얼 보고 조정 필요
local hopForwardTilt = math.rad(10)
local hopLiftPower = 3 -- lift = raw^hopLiftPower. 클수록 바닥 근처에 오래 머물다 순간적으로 튀어오르는 홉 느낌
local hopEarWiggle = math.rad(10)
local hopTailSway = math.rad(30)

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

function Pet_03_Anim.Idle(pet: Model, joints: { [string]: Motor6D }, elapsed: number, _ctx: { [string]: any }, scale: number?)
	local s = osc(elapsed, 0, cycleDuration)
	local lift = (s + 1) / 2 -- -1~1을 0~1로 이동: 멈추는 구간 없이 계속 오르내리되 기준보다 아래로는 안 내려감
	local sc = safeScale(scale)

	local bodyPart = pet:FindFirstChild("Body")
	if bodyPart and bodyPart:IsA("BasePart") then
		bodyPart.CFrame = bodyPart.CFrame * CFrame.new(0, bodyBob * sc * lift, 0)
	end

	MotorJointAnimator.applyJointTransform(joints.EarLJoint, CFrame.Angles(0, 0, -earWiggle * s))
	MotorJointAnimator.applyJointTransform(joints.EarRJoint, CFrame.Angles(0, 0, earWiggle * s))
	-- 속귀/코 보조 파츠는 부모(겉귀/코)를 그대로 따라가도록 항등 트랜스폼만 매 프레임 재적용한다
	-- (호출 자체를 생략하면 PetManager의 PivotTo가 매 프레임 Body를 리셋하는 트릭을 상쇄할 수 없어
	-- 서서히 아래로 드리프트됨).
	MotorJointAnimator.applyJointTransform(joints.EarLInnerJoint, CFrame.new())
	MotorJointAnimator.applyJointTransform(joints.EarRInnerJoint, CFrame.new())

	MotorJointAnimator.applyJointTransform(joints.SnoutJoint, CFrame.new(0, -snoutMove * sc * s, 0))
	MotorJointAnimator.applyJointTransform(joints.SnoutExtraJoint, CFrame.new())

	MotorJointAnimator.applyJointTransform(joints.TailJoint, CFrame.Angles(0, tailSway * s, 0))

	local footShiftSc = footShift * sc
	MotorJointAnimator.applyJointTransform(joints.FootFLJoint, CFrame.new(0, footShiftSc * s, 0))
	MotorJointAnimator.applyJointTransform(joints.FootFRJoint, CFrame.new(0, footShiftSc * s, 0))
	MotorJointAnimator.applyJointTransform(joints.FootBLJoint, CFrame.new(0, -footShiftSc * s, 0))
	MotorJointAnimator.applyJointTransform(joints.FootBRJoint, CFrame.new(0, -footShiftSc * s, 0))
end

function Pet_03_Anim.Move(pet: Model, joints: { [string]: Motor6D }, elapsed: number, _ctx: { [string]: any }, scale: number?)
	local raw = osc(elapsed, 0, hopCycleDuration)
	local lift = math.max(raw, 0) ^ hopLiftPower -- 지수가 클수록 바닥에 오래 머물다 순간적으로 튀는 홉 느낌
	local sc = safeScale(scale)

	local bodyPart = pet:FindFirstChild("Body")
	if bodyPart and bodyPart:IsA("BasePart") then
		bodyPart.CFrame = bodyPart.CFrame
			* CFrame.new(0, hopBodyBob * sc * lift, -hopLungeStuds * sc * lift)
			* CFrame.Angles(-hopForwardTilt * lift, 0, 0)
	end

	MotorJointAnimator.applyJointTransform(joints.EarLJoint, CFrame.Angles(0, 0, -hopEarWiggle * raw))
	MotorJointAnimator.applyJointTransform(joints.EarRJoint, CFrame.Angles(0, 0, hopEarWiggle * raw))
	MotorJointAnimator.applyJointTransform(joints.EarLInnerJoint, CFrame.new())
	MotorJointAnimator.applyJointTransform(joints.EarRInnerJoint, CFrame.new())

	MotorJointAnimator.applyJointTransform(joints.SnoutJoint, CFrame.new(0, -snoutMove * sc * raw, 0))
	MotorJointAnimator.applyJointTransform(joints.SnoutExtraJoint, CFrame.new())

	MotorJointAnimator.applyJointTransform(joints.TailJoint, CFrame.Angles(0, hopTailSway * raw, 0))

	-- 대각선 트롯이 아니라 네 다리가 동시에 접혔다 펴짐(홉 모션)
	local footY = hopFootLift * sc * lift
	MotorJointAnimator.applyJointTransform(joints.FootFLJoint, CFrame.new(0, footY, 0))
	MotorJointAnimator.applyJointTransform(joints.FootFRJoint, CFrame.new(0, footY, 0))
	MotorJointAnimator.applyJointTransform(joints.FootBLJoint, CFrame.new(0, footY, 0))
	MotorJointAnimator.applyJointTransform(joints.FootBRJoint, CFrame.new(0, footY, 0))
end

return Pet_03_Anim
