--[[
	스테이지가 끝났는지(클리어/오버) 여부를 stage 클라이언트 팝업들이 공유해서 참조하기 위한
	아주 작은 상태 저장소.

	GameClearPopup/GameOverPopup은 뜨기 시작하는 즉시 markEnded()를 호출한다. PetSavedPopup처럼
	스테이지 도중 아무 때나(서버가 임의 시점에 보내는 이벤트로) 뜰 수 있는 팝업은 열기 전에
	isEnded()를 확인해서 건너뛴다.

	이게 필요한 이유: 보스를 잡으면 같은 프레임에 StageClearedEvent와(보스가 SpeechBubbleGui를
	가지고 있었다면) PetSavedEvent가 거의 동시에 발사되는데, 네트워크 도착 순서나 GameClearPopup의
	연출(TweenService...Wait(), task.wait() 등 여러 yield)이 진행되는 동안 PetSavedEvent가 뒤늦게
	처리되면 PetSavedPopup이 그 위에 겹쳐 뜬다. GameClearPopup 쪽 pushPopup(closeOthers=true)는
	"자신보다 먼저 열려 있던 팝업을 닫는" 것만 처리하고, 반대로 자신보다 나중에 열리려는 팝업을
	막지는 못하므로, PetSavedPopup 쪽에서 스스로 열기를 건너뛰도록 해야 한다.
]]

local StageEndState = {}

local ended = false

function StageEndState.markEnded()
	ended = true
end

function StageEndState.isEnded(): boolean
	return ended
end

return StageEndState
