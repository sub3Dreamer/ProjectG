# Portal setup for Stage 2
_Exported on 9/18/2026 at 09:36:57 GMT+9 from Cursor (3.20.21)_

---

**User**

lobby의 Portal을 세팅할때 StageNumber가 2일경우 Difficulty 특성 대신에 Team을 사용할거야(string, Red/Blue)
JoinCnt만큼 Billboard에 현황 표시해주고
해당 포탈에 플레이어가 입장시 PvpPopup을 보여줘. 
PvpPopup의 PlayerInfo에 Team정보도 추가해서 팀구분을 하고 슬롯배치도 팀에 맞게 적용해줘.

해당 포탈은 Red, Blue 양팀 2명씩 모두 입장한경우 Teleporting상태로 전환되고 Stage2 플레이스로 이동시켜줘.

---

**Cursor**

StageNumber 2 포탈에 Team 기반 입장·PvpPopup·텔레포트를 붙이려면 먼저 기존 Portal/PvpPopup 구조를 확인하겠습니다.

핵심 서버·팝업 코드를 읽고 Stage2 Team 플로우를 구현합니다.

`PvpRoomManager`를 추가하고 PortalHandler·UI·팝업을 Stage2 Team 플로우에 맞게 연결합니다.

PortalLobbyWarp·RoomManager·PortalHandler를 이어서 수정합니다.

PortalUI·PvpPopup·PortalWarp를 Stage2 Team에 맞게 수정합니다.

Stage 2 PVP 포탈 플로우를 연결했습니다.

### 동작
- **StageNumber = 2** 포탈은 `Difficulty` 대신 **`Team` (`"Red"` / `"Blue"`)** 로 입장
- 입장 즉시 **PvpPopup** 오픈, Billboard에 **`현재인원 / JoinCnt`** 표시
- `PlayerInfo`에 **`Team`** 추가 → Blue/Red 슬롯 배치
- Red·Blue 각 팀 `JoinCnt`(기본 2) 충족 시 **Teleporting** → Stage2 PlaceId로 이동

### 스튜디오 세팅
각 Stage2 포탈에:

| Attribute | 값 |
|-----------|-----|
| `Portal` | `true` |
| `StageNumber` | `2` |
| `Team` | `"Red"` 또는 `"Blue"` |
| `JoinCnt` | `2` |

### 주요 파일
- `PvpRoomManager.luau` — 서버 매치/텔레포트
- `PortalHandler` — Stage2 → PVP 분기
- `PortalUI` / `PvpPopup` / `PortalWarp` — Billboard·팝업·팀 워프

---

**User**

PortalHandler의 bindPortal에서 Difficulty특성이 없는 문제로 Pvp포탈이 필터링이 되고있는데 해당 예외처리 수정해줘.

---

**Cursor**

PortalHandler의 `bindPortal`에서 Stage2 PVP가 Difficulty 검사에 걸려 걸러지는지 확인합니다.

`stage == PVP_STAGE` 비교가 어긋나면 Difficulty 분기로 떨어질 수 있어, `Team`이 있으면 Difficulty 없이 PVP로 바인딩하도록 바꿉니다.

`PVP_STAGE`가 nil이거나 스테이지 비교가 어긋나면 Difficulty 분기로 떨어집니다. `Team`이 있으면 Difficulty 없이 PVP로 등록하도록 고칩니다.

수정했습니다.

`bindPortal`에서 **`Team`이 `Red`/`Blue`이면 Difficulty 검사 없이 PVP로 등록**하도록 바꿨습니다. StageNumber 비교만으로 분기하던 경로에서 Difficulty 필수로 떨어지던 문제를 막았습니다.

터치 입장(`onPortalTouched`)과 클라 `PortalUI` 바인딩도 같은 기준으로 맞춰 두었습니다.

---

**User**

Pvp포탈에 PortalNumber 특성을 추가했어. Pvp 방 입장/퇴장이 해당 PortalNumber에 종속되도록 변경해줘.

그리고 Pvp포탈은 입장/퇴장시 billboardGui에서 Exit버튼이 노출되면 안되고 StatusText만 갱신되어야해.

---

**Cursor**

PortalNumber로 PVP 방을 분리하고, Billboard에서는 Exit를 숨기고 StatusText만 갱신하도록 수정합니다.

PortalNumber 단위로 매치를 분리하고, PVP Billboard에서는 Exit를 숨기도록 수정합니다.

반영했습니다.

### PortalNumber
- 같은 `PortalNumber`의 Red/Blue 포탈만 한 PVP 방을 공유합니다.
- `PortalHandler` / `PortalUI` 바인딩에 `PortalNumber` 필수 검사 추가
- 퇴장·워프도 해당 `PortalNumber` 기준으로 처리

### Billboard
- PVP 포탈은 **ExitButton 항상 숨김**
- **StatusText**만 `N / JoinCnt` 갱신
- 퇴장은 **PvpPopup**에서만 가능

