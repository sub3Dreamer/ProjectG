--[[
	CostumeAvatarPreview (lobby client)

	CostumePopup에서 코스튬 선택/해제 시 서버(CostumeHelper.requestPreview)에 미리보기 적용을 요청하는 얇은 래퍼.

	실제 캐릭터 외형 적용/복원 로직은 전부 서버 측(src/shared/Helpers/CostumeHelper.luau)에서 처리한다.
	Humanoid:AddAccessory()를 LocalScript에서 호출하면 엔진이 거부하고, 레이어드 클로딩(Cage/Wrap 체형 변형)도
	클라이언트에서는 재현할 수 없어 서버 기반으로 전환했다 — 이 미리보기는 다른 플레이어에게도 보인다(의도된 트레이드오프).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CostumeHelper = require(Shared.Helpers.CostumeHelper)

local CostumeAvatarPreview = {}

function CostumeAvatarPreview.apply(costumeId: string)
	CostumeHelper.requestPreview(costumeId)
end

function CostumeAvatarPreview.clear()
	CostumeHelper.requestPreview(nil)
end

return CostumeAvatarPreview
