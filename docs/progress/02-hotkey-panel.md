# 02 — hotkey-panel

글로벌 핫키 + 포커스를 뺏지 않는(non-activating) 프롬프트 패널. PLAN.md의 최대 리스크
(non-activating 패널의 포커스 유지)를 선행 검증하는 단계.

## 구현 내용

### 1. 글로벌 핫키 (`HotkeyManager.swift`)
- Carbon `RegisterEventHotKey` 사용. 앱이 비활성 상태여도 발동하고, 등록 자체는
  접근성 권한 불필요 (`CGEventTap` 방식과 달리). 앱 전체 기능은 어차피 AX 권한 필요.
- 기본값 하드코딩: `⌘⇧Space` (`kVK_Space` + `cmdKey | shiftKey`).
- UserDefaults 키로 오버라이드 (설정 UI는 6단계):
  - `hotkeyKeyCode` — virtual key code (기본 `kVK_Space`)
  - `hotkeyModifiers` — Carbon modifier 마스크 (기본 `cmdKey | shiftKey`)
- Carbon C 콜백 → `Unmanaged`로 `self` 전달 → 메인 액터로 hop 후 Swift 핸들러 호출.
- `signature = 'ALLM'`, id=1 단일 핫키. `RegisterEventHotKey` 실패(시스템 충돌) 시
  `NSLog` 경고만 남기고 크래시 안 함.

### 2. non-activating 패널 (`PromptPanel.swift`)
- `NSPanel` 서브클래스, `styleMask = [.nonactivatingPanel, .titled, .fullSizeContentView]`.
  - `.titled + .fullSizeContentView` 로 타이틀바를 숨겨 표준 둥근 모서리/그림자만 취함
    (borderless보다 시각적으로 자연스럽고 first-responder 문제 없음).
- `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`.
- `canBecomeKey = true` (키 입력 수신), `canBecomeMain = false` (앱 활성화/메뉴바 이동 차단).
- `hidesOnDeactivate = false`, `isReleasedWhenClosed = false`.
- 내용물: 임시 `NSTextField` 하나 (진짜 대화 UI는 5단계). Esc(`cancelOperation`)로 닫기.

### 3. 패널 위치 (`PanelPositioner.swift`)
- UserDefaults `panelPosition`: `caret`(기본) / `mouse` / `center`.
- caret 3단 폴백:
  1. 포커스 요소의 `kAXSelectedTextRange` → `kAXBoundsForRangeParameterizedAttribute`로 캐럿 bounds.
  2. 실패 시 포커스 요소 `AXFrame`.
  3. 실패 시 마우스 위치.
- **좌표 변환 주의**: AX 좌표는 top-left 원점(주 화면 상단 기준), NSScreen/NSWindow는
  bottom-left 원점. `cocoaRect(fromAXTopLeft:)`에서 주 화면 높이로 y축 flip.
- 화면 경계 클램핑: 패널이 걸치는 화면의 `visibleFrame`(메뉴바/Dock 제외) 안으로 origin 보정.
- AX 코드는 위치 계산에 필요한 최소한만 `PanelPositioner` 안에 자체 포함
  (다른 에이전트의 `AXTextTarget*` 영역 침범 안 함).

### 4. AppDelegate 연결 (`AppDelegate.swift`)
- `applicationDidFinishLaunching`에서 `HotkeyManager` 시작, 핸들러 = `togglePanel()`.
- `togglePanel()`: 이미 보이면 `orderOut`, 아니면 **현재 포커스 기준**으로 위치 계산 →
  `orderFrontRegardless()`(앱 활성화 없이 표시) → `makeKey()` → `focusInput()`.
- 위치 계산은 패널을 띄우기 **전에** 해야 함 (띄운 뒤엔 포커스가 바뀔 수 있음).

## 포커스 유지 메커니즘 (핵심)

대상 앱이 활성 상태로 남는 이유:
1. `.nonactivatingPanel` styleMask — 이 패널이 key window가 되어도 소속 앱이 activate 되지 않음.
2. `orderFrontRegardless()` — `makeKeyAndOrderFront`와 달리 앱을 activate 하지 않고 창만 앞으로.
3. `canBecomeMain = false` — 패널이 main window가 되는 것을 막아 메뉴바가 우리 앱 것으로
   바뀌지 않게 함. `canBecomeKey = true`라 키 입력은 정상 수신.
4. 앱 activation policy는 `.accessory` (scaffold 단계) — 애초에 Dock/메뉴바 존재감 최소.

결과 기대: 패널에 타이핑하는 동안 대상 앱(예: Safari)이 frontmost로 남고 메뉴바도
대상 앱 것으로 유지. 캐럿 추적 시 대상 앱 텍스트박스의 캐럿 위치를 AX로 읽어옴.

## 공개 인터페이스 (5단계 integration이 이어받는 지점)

- `AppDelegate.togglePanel()` — private. 핫키가 호출. integration에서 패널 내용/플로우 교체 시
  `PromptPanel`의 `contentView`를 실제 대화 UI로 교체.
- `PromptPanel`:
  - `init()` — 패널 생성.
  - `focusInput()` — 입력 필드에 first responder 부여.
  - `cancelOperation(_:)` — Esc로 `orderOut`.
  - 표시: `panel.orderFrontRegardless(); panel.makeKey()`. 숨김: `panel.orderOut(nil)`.
- `PanelPositioner.origin(for size: NSSize) -> NSPoint` — Cocoa(bottom-left) origin 반환.
  패널 크기만 넘기면 됨. 내부에서 `panelPosition` 설정 읽고 3단 폴백 + 클램핑.
- `HotkeyManager(handler:)` / `start()` / `stop()` — 핸들러 클로저로 토글 동작 주입.

## 빌드 결과 (자동)

- `swift build` 성공, 경고 0.
- (동시 빌드 중이던 다른 에이전트의 `LLMClient`/`LLMCore` 일시적 오류는 그쪽 완료 후 해소됨.)

## 사용자 수동 확인 필요 (GUI 실측, 에이전트 불가)

1. **핫키 발동**: 임의 앱에서 `⌘⇧Space` → 패널이 뜨는지. (앱 실행 + AX 권한 허용 상태 필요.)
2. **포커스 유지 (최대 리스크)**: 패널이 뜬 상태에서 타이핑할 때
   - 대상 앱(예: Safari, TextEdit)이 계속 frontmost 인지 (타이틀바 강조 유지).
   - 메뉴바가 대상 앱 메뉴로 남아있는지 (우리 앱으로 안 바뀜).
   - 대상 앱의 텍스트 커서(캐럿)가 그대로인지.
3. **핫키 토글**: 다시 `⌘⇧Space` 또는 Esc로 패널이 닫히는지.
4. **캐럿 위치**: 텍스트박스에 캐럿 두고 핫키 → 패널이 캐럿 근처(바로 아래)에 뜨는지.
   - AX 미지원 앱에선 포커스 요소 frame → 마우스 위치로 폴백. 앱별 편차 실측 필요.
5. **멀티 모니터 / 전체화면**: 다른 스페이스·전체화면 앱 위에서도 패널이 뜨는지
   (`canJoinAllSpaces`, `fullScreenAuxiliary`).
6. **핫키 충돌**: `⌘⇧Space`가 다른 앱/시스템 단축키(일부 입력기)와 충돌하는지.
   충돌 시 `RegisterEventHotKey` 실패 → 콘솔에 경고 로그. 설정 UI(6단계) 전엔
   UserDefaults로 수동 변경 가능.
