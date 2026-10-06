# FinderPin

다른 앱을 클릭해도 Finder 창을 다른 일반 앱 창보다 위에 보이게 유지하는 메뉴바 유틸리티입니다.
Finder 창은 Column View로 강제합니다.

## 동작 방식 (중요)

SIP를 켠 macOS에서는 **다른 프로세스(Finder) 창의 window level을 바꿀 수 없습니다** (macOS 26.6.2에서 직접 확인):

| 방법 | 결과 |
|---|---|
| `AXRaise` (공개 API, Hammerspoon `hs.window:raise()`와 같음) | 활성 앱 창 **바로 아래**까지만 올라감 |
| `SLSSetWindowLevel` (private SkyLight) | 에러 없이 반환되지만 서버 측 layer는 0 그대로 |
| `SLSOrderWindow` (private SkyLight) | `kCGErrorFailure (1000)` |
| yabai `window --layer above` | Dock에 scripting addition을 주입해야 해서 SIP 일부 해제 필요 |

그래서 FinderPin은 **고정된 Finder 창마다 자기 소유의 `.floating` 패널(오버레이)을 창 위에 정확히 겹쳐 놓고,
ScreenCaptureKit으로 Finder 창을 실시간 캡처해 보여줍니다.**

- Finder가 활성 상태일 때: 오버레이를 숨깁니다 (실제 Finder 창이 이미 맨 위에 있음).
- 다른 앱이 활성 상태일 때: 오버레이를 표시합니다 → Finder 창이 계속 위에 보입니다.
- 오버레이를 클릭하거나 파일을 끌어다 올리면: 실제 Finder 창을 raise하고 Finder를 활성화합니다.
- Finder가 활성 상태에서 다른 앱을 클릭하거나 ⌘Tab을 누르면, 이벤트 탭이 입력이 그 앱에 전달되기 **전에**
  오버레이를 먼저 올립니다. 그래서 Finder 창이 잠깐 뒤로 갔다가 돌아오는 깜빡임이 없습니다.
- 캡처는 창이 있는 디스플레이의 배율(1x/2x)과 색공간(P3/sRGB)을 따라가므로, 모니터 사이를 옮겨도 선명도와 색이 유지됩니다.

## 기능

- Finder 창이 열리면 자동 고정 (메뉴에서 끌 수 있음), 여러 창 각각 고정
- `⌥⌘Space`: Finder 활성화. 현재 Space에 Finder 창이 없으면 **마지막으로 닫은 창의 폴더와 위치**로 새 창을 엽니다.
  macOS 기본 단축키 "Finder 검색 윈도우 보기"(⌥⌘Space)는 FinderPin이 실행 중일 때만 꺼지고, 종료하면 복원됩니다.
  폴더는 경로 막대에서 읽으므로 Finder ▸ 보기 ▸ 경로 막대 보기가 켜져 있어야 합니다.
- `⌃⌥⌘P`: 현재 Finder 창 고정/해제 (Finder가 비활성 상태면 마우스 아래 Finder 창 대상)
- 메뉴바: 전체 ON/OFF, 새 창 자동 고정, Column View 강제, 창별 고정 체크, 권한 상태, 로그인 시 실행
- Column View 강제: 새 창이 생기거나, 포커스/폴더가 바뀌거나, Finder가 활성화될 때 Column View가 아니면
  Finder의 `보기 ▸ 계층(⌘3)` 메뉴를 AX로 누릅니다 (단축키로 찾기 때문에 언어와 상관없음)
- 전체화면 앱 Space에서는 Finder 창이 화면에 없으므로 아무것도 덮지 않음

## 빌드 / 설치

```bash
./scripts/install.sh      # 빌드 → /Applications/FinderPin.app 설치 → 실행
```

메뉴바 전용 앱(LSUIElement)이라 Dock에는 나타나지 않고 메뉴바의 📌 아이콘으로 제어합니다.

필요한 권한 (시스템 설정 ▸ 개인정보 보호 및 보안):

1. **손쉬운 사용**: FinderPin 켜기 (Finder 창 감지, raise, 메뉴 누르기)
2. **화면 및 시스템 오디오 녹음**: FinderPin 켜기 (창 미러링). 허용한 뒤 메뉴의 "다시 시작"으로 재실행하세요.
3. "…윈도우 선택기를 우회하여 화면에 접근" 팝업이 뜨면 **허용**을 누르세요. macOS가 주기적으로 다시 물을 수 있습니다.

AppleScript/Automation 권한은 필요 없습니다.

### 재빌드할 때 권한이 풀리는 문제

ad-hoc 서명은 빌드할 때마다 코드 해시가 바뀌어서 macOS가 권한을 잊어버립니다. 키체인 접근 ▸ 인증서 지원 ▸
인증서 생성(유형: 코드 서명)으로 자체 서명 인증서(예: `FinderPin Dev`)를 만든 뒤 아래처럼 빌드하세요:

```bash
FINDERPIN_SIGN_ID="FinderPin Dev" ./scripts/build-app.sh
```

## 알려진 제약

- 오버레이는 실시간 캡처 화면입니다. 처음 클릭하면 Finder가 활성화만 되고, 그 클릭이 파일 선택으로 전달되지는 않습니다.
  비활성 상태에서는 hover나 스크롤도 반응하지 않습니다.
- 마우스 클릭과 ⌘Tab 이외의 방법(Spotlight, 다른 앱의 단축키, 알림 클릭 등)으로 전환하면 짧은 깜빡임이 남을 수 있습니다.
- 다른 앱의 floating 창이나 더 높은 레벨의 창(예: 일부 ChatGPT 창, PiP, 시스템 패널)은 Finder 위에 올 수 있습니다.
- 진짜 window level 변경이 꼭 필요하면 yabai + scripting addition(SIP 일부 해제)이 유일한 방법입니다.
