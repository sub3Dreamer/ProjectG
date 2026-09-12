--[[
	난이도(1=Easy/2=Normal/3=Hard) 공용 정의.
	PartyPopup.luau(표시 라벨), RoomManager.luau(표시 라벨 + 유효성 검사),
	DamageableObjectStats.luau(HitPoint JSON 소문자 키)에서 공용으로 참조.
]]

return {
	Easy = 1,
	Normal = 2,
	Hard = 3,

	labelKeys = { -- StringData 키 (표시용)
		[1] = "Difficulty_Easy",
		[2] = "Difficulty_Normal",
		[3] = "Difficulty_Hard",
	},

	statKeys = { -- HitPoint JSON 소문자 키
		[1] = "easy",
		[2] = "normal",
		[3] = "hard",
	},
}
