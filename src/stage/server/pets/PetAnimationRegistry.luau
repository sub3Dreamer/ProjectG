--[[
	petId → 애니메이션 모듈 매핑.
	PetManager가 스폰 시 이 테이블로 각 펫의 Idle/Move 핸들러를 조회한다.
]]

local animations = script.Parent:WaitForChild("animations")

local PetAnimationRegistry = {
	["Pet_01"] = require(animations:WaitForChild("Pet_01_Anim")),
	["Pet_02"] = require(animations:WaitForChild("Pet_02_Anim")),
	["Pet_03"] = require(animations:WaitForChild("Pet_03_Anim")),
	["Pet_04"] = require(animations:WaitForChild("Pet_04_Anim")),
	["Pet_05"] = require(animations:WaitForChild("Pet_05_Anim")),
	["Pet_06"] = require(animations:WaitForChild("Pet_06_Anim")),
	["Pet_07"] = require(animations:WaitForChild("Pet_07_Anim")),
	["Pet_08"] = require(animations:WaitForChild("Pet_08_Anim")),
	["Pet_09"] = require(animations:WaitForChild("Pet_09_Anim")),
	["Pet_10"] = require(animations:WaitForChild("Pet_10_Anim")),
	-- 앞으로 펫 추가 시 이 네이밍(Pet_11_Anim, ... Pet_99_Anim)으로 통일
}

return PetAnimationRegistry
