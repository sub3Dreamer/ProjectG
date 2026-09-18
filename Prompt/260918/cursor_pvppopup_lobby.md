# PvpPopup lobby
_Exported on 9/18/2026 at 09:16:08 GMT+9 from Cursor (3.20.21)_

---

**User**

src/lobby/client/popup 디렉토리에 PvpPopup.luau 구현해줘.
​로블록스 스튜디오 프로젝트야.

개요 : 실시간으로 Blue, Red팀에 플레이어 입장을 받는다. 각 팀에 플레이어가 2명씩 입장할수있다. 나가기 버튼이나 우측 상단 X버튼을 통해 퇴장할수있으며, 플레이어 입장이나 퇴장 이벤트 발생시 입장 상태인 모든 플레이어의 화면에 상태가 갱신되어야한다. 각 Profile에는 플레이어의 기본 아바타 아이콘과 닉네임이 노출된다.

- 프로필
  - 플레이어의 기본 아바타 아이콘 
    - 경로 : PvpPopup/Container/Team_Blue or Team_Red/Profiles/Profile/ImgProfile 
    - 속성 : ImageLabel
    - 기능 : 해당 프로필에 보여줄 PlayerInfo의 UserId정보로 아바타 이미지를 로드해서 노출함.
  - 플레이어의 닉네임 
    - 경로 : PvpPopup/Container/Team_Blue or Team_Red/Profiles/Profile/TxtNickName 
    - 속성 : TextLabel
    - 기능 : 해당 프로필에 보여줄 PlayerInfo의 DisplayName을 텍스트로 노출함.
  - 로딩 상태
    - 경로 : PvpPopup/Container/Team_Blue or Team_Red/Profiles/Profile/Loading
    - 속성 : Frame
=> 해당 프로필 슬롯에 플레이어가 존재시 ImgProfile과 TxtNickname의 Visible을 활성화하고 해당 정보를 디스플레이한다. 이때 Loading의 Visible은 비활성화 된다. 플레이어 입장시 해당 팝업에 PlayerInfo정보를 인자로 받아야한다. PlayerInfo에는 아바타 아이콘을 띄울 UserId와 닉네임을 표시할 DisplayName 정보가 존재함.
해당 슬롯에 입장한 플레이어가 없을경우 프로필과 닉네임은 Visible이 비활성화되고 Loading의 Visible이 활성화된다.

- 퇴장
  - 나가기 버튼  
    - 경로 : PvpPopup/Container/ExitButton
    - 속성 : TextButton
  - X 버튼
    - 경로 : PvpPopup/Top/CloseButton
    - 속성 : TextButton
=> 해당 Pvp 파티에서 퇴장 처리를 하고 팝업을 닫는 기능을한다.

---

**Cursor**

다른 팝업 구현과 PlayerInfo 구조를 먼저 확인한 뒤, 그 패턴에 맞춰 `PvpPopup.luau`를 작성하겠습니다.

기존 팝업 패턴에 맞춰 `PvpPopup.luau`를 추가하고, 로비 클라이언트에서 초기화되도록 연결합니다.

`addPlayer`가 열린 팝업의 로스터를 제대로 갱신하도록 고치고, `GetDebugId` 사용도 제거하겠습니다.

