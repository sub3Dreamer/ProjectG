--[[
	Motor6D 조인트를 이름으로 수집하고, Anchored된 파츠에서도 동작하도록
	Part1의 CFrame을 직접 계산해 적용하는 공용 유틸.

	Anchored=true인 파츠는 Motor6D.Transform을 바꿔도 물리 시뮬레이션이 없어
	자동으로 반영되지 않으므로, Part0.CFrame * C0 * Transform * C1:Inverse()를
	매 프레임 직접 대입해야 한다.
]]

local MotorJointAnimator = {}

function MotorJointAnimator.collectMotor6Ds(model: Model): { [string]: Motor6D }
	local joints: { [string]: Motor6D } = {}
	for _, child in model:GetDescendants() do
		if child:IsA("Motor6D") then
			joints[child.Name] = child
		end
	end
	return joints
end

function MotorJointAnimator.applyJointTransform(joint: Motor6D?, transformCFrame: CFrame)
	if not joint then
		return
	end
	local part0, part1 = joint.Part0, joint.Part1
	if not (part0 and part1) then
		return
	end
	part1.CFrame = part0.CFrame * joint.C0 * transformCFrame * joint.C1:Inverse()
end

return MotorJointAnimator
