# PortalUI model scan scope
_Exported on 9/18/2026 at 09:17:16 GMT+9 from Cursor (3.20.21)_

---

**User**

lobby의 PortalUI에서 기존기능이 bindPedestal할때 workspace 하위 모든 모델을 스캔하는 방식으로 구현돼있는것 같은데 
Portal 폴더 하위에 있는 모든 모델을 스캔하는 방식으로 변경해줘.

---

**Cursor**

PortalUI에서 pedestal 바인딩 스캔 범위를 Workspace 전체가 아닌 Portal 폴더로 좁히겠습니다.

`scanAll`과 `DescendantAdded`/`DescendantRemoving` 리스너를 `Workspace.Portal` 하위로 한정하겠습니다.

변경 완료했습니다. 이제 pedestal 바인딩은 `Workspace` 전체가 아니라 `Workspace.Portal`만 봅니다.

- `scanAll` → `Portal` 폴더 descendants만 스캔
- `DescendantAdded` / `DescendantRemoving` → `Portal` 폴더에만 연결
- 폴더가 없으면 `WaitForChild` 후 warn하고 중단

