--[[
	로비 파티 잠금용 CollisionGroup 이름 (서버/클라 동일하게 사용).

	벽 Part 에 Attribute LobbyLockWall=true 를 넣으면 서버가 시작 시,
	가장 가까운 Portal 인스턴스에 매칭해 그 포탈 전용 CollisionGroup(LOCK_WALL_GROUP_PREFIX + 일련번호)으로 설정한다.
	포탈마다 벽 그룹이 분리되어 있어야 한 포탈의 LockWall On/Off 가 다른 포탈에 영향을 주지 않는다.

	LOCKED_MEMBER 는 포탈 간 공유되는 단일 그룹이다. 잠긴 캐릭터는 자기 포탈의 벽 반경 안에만
	있으므로(레벨 디자인상 LockWall 이 포탈 주변을 둘러쌈) 공유해도 실질적으로 문제되지 않는다.

	기본적으로 각 포탈 LOCK_WALL 그룹은 Default 와 충돌하지 않고 LOCKED_MEMBER 와만 충돌한다.
	로비 RoomManager 가 해당 포탈에서 PopupOpen / Teleporting 일 때만 그 포탈 그룹의 Default 와의 충돌을 켠다.
]]

return table.freeze({
	LOCKED_MEMBER = "LobbyLockedMember",
	-- 포탈별로 동적 등록되는 CollisionGroup 이름 접두사 (예: "LobbyLockedWall_3")
	LOCK_WALL_GROUP_PREFIX = "LobbyLockedWall_",
	-- BasePart Attribute 이름 (true 이면 가장 가까운 포탈의 LOCK_WALL 그룹으로 등록)
	ATTR_LOCK_WALL = "LobbyLockWall",
})
