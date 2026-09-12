--[[
	점프 비활성: JumpPower 0, Jumping 상태 비활성, AutoJump 끔.
	터치 점프 버튼은 StarterPlayer.EnableTouchJump = false (프로젝트 JSON 또는 Studio).
]]

local JumpControl = {}

function JumpControl.applyToHumanoid(humanoid: Humanoid)
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 0
	humanoid.AutoJumpEnabled = false
	pcall(function()
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	end)
end

function JumpControl.applyToCharacter(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		JumpControl.applyToHumanoid(humanoid)
	end
end

return JumpControl
