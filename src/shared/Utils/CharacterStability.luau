--[[
	작은·움직이는 물체를 밟을 때 미끄러짐·튐 완화: HRP 밀도↑, 발·다리·몸통 마찰↑, 탄성 0에 가깝게.
]]

local GameSettings = require(script.Parent.Parent.Config.GameSettings)

local CharacterStability = {}

local STABILITY_PART_NAMES: { [string]: boolean } = {
	HumanoidRootPart = true,
	UpperTorso = true,
	LowerTorso = true,
	Torso = true,
	LeftFoot = true,
	RightFoot = true,
	LeftLowerLeg = true,
	RightLowerLeg = true,
	LeftUpperLeg = true,
	RightUpperLeg = true,
	["Left Leg"] = true,
	["Right Leg"] = true,
}

function CharacterStability.apply(character: Model)
	local cfg = GameSettings.CharacterStability
	if typeof(cfg) ~= "table" or cfg.Enabled == false then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		-- StepHeight는 일부 엔진/버전에서 Humanoid에 없을 수 있음
		local stepH = cfg.StepHeight or 0
		pcall(function()
			(humanoid :: any).StepHeight = stepH
		end)
		pcall(function()
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
		end)
	end

	local rootDensity = cfg.HumanoidRootPartDensity or 2.2
	local rootFriction = cfg.HumanoidRootPartFriction or 1.85
	local limbFriction = cfg.LimbFriction or 1.75
	local elasticity = cfg.Elasticity or 0

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		hrp.CustomPhysicalProperties = PhysicalProperties.new(rootDensity, rootFriction, elasticity)
	end

	local limbDensity = cfg.LimbDensity or 0.7
	for _, inst in character:GetDescendants() do
		if inst:IsA("BasePart") and STABILITY_PART_NAMES[inst.Name] and inst ~= hrp then
			inst.CustomPhysicalProperties = PhysicalProperties.new(limbDensity, limbFriction, elasticity)
		end
	end
end

return CharacterStability
