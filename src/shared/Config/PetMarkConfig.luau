--[[
	펫 건물 마킹 시스템 밸런스 설정 ("펫 건물 마킹 시스템.md" 8장 참고).

	전역 고정 사이클: 스테이지 시작(StageManager.StageStartedAt) 기준 MarkStartTime(40초)에 첫
	펫마커가 발생하고, RescueDuration(10초) 동안 구출 가능하다. 이후 (MarkStartTime+RescueDuration)
	초 단위로 동일 구조가 반복된다. 펫마커 발생 AreaNoticeTime(5초) 전에 플레이어별 Area 3개
	(AreaCount)를 위치/레벨 기준으로 선정하고 사전 안내한다.

	AreaByLevel 수치는 초기 테스트용 placeholder다(구 SpeechBubbleConfig.TargetByLevel의 거리값을
	이관). 맵 실제 크기를 반영한 값이 아니므로 Studio에서 실측 후 조정할 것.
]]

return {
	-- 게임 시작 후 최초 펫마커 발생 시각(초)
	MarkStartTime = 40,
	-- 펫마커 발생 후 구출(건물 파괴) 가능 시간(초)
	RescueDuration = 10,
	-- 펫마커 발생 전 Area 선정/사전 안내 리드타임(초)
	AreaNoticeTime = 5,

	-- 플레이어 1인당 생성되는 Area 개수 (= 펫마커 후보 개수)
	AreaCount = 3,

	-- Area/대체 건물 탐색 실패 시 탐색 범위 확장 배율
	SpawnRangeExpandMultiplier = 2,

	-- 레벨별 Area 설정
	AreaByLevel = {
		[1] = { AreaRadius = 20, SpawnRangeMin = 40, SpawnRangeMax = 80 },
		[2] = { AreaRadius = 30, SpawnRangeMin = 50, SpawnRangeMax = 100 },
		[3] = { AreaRadius = 40, SpawnRangeMin = 60, SpawnRangeMax = 120 },
		[4] = { AreaRadius = 50, SpawnRangeMin = 70, SpawnRangeMax = 140 },
		[5] = { AreaRadius = 70, SpawnRangeMin = 85, SpawnRangeMax = 170 },
		[6] = { AreaRadius = 90, SpawnRangeMin = 100, SpawnRangeMax = 200 },
		[7] = { AreaRadius = 110, SpawnRangeMin = 120, SpawnRangeMax = 240 },
		[8] = { AreaRadius = 130, SpawnRangeMin = 150, SpawnRangeMax = 300 },
	},
}
