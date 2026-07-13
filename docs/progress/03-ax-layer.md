# 03 — ax-layer

포커스된 텍스트 요소 읽기/쓰기 추상화. AX API 우선, 실패 시 클립보드 백업/복원 + ⌘C/⌘V 이벤트 폴백. 보안 필드는 하드 차단.

## 파일

```
Sources/AnywhereLLM/TextTarget.swift
```

독립 모듈 — AppDelegate/HotkeyManager/PromptPanel/LLM* 은 건드리지 않음. 5단계(integration)에서 호출됨.

## 공개 인터페이스

```swift
struct TargetContext {
    let appName: String?        // 대상 앱 localizedName
    let bundleId: String?
    let selectedText: String?   // nil = 선택 없음 (또는 보안 필드)
    let fullText: String?       // 전체 필드 내용 (보안 필드면 nil, off 설정 시 호출측 무시)
    let isSecureField: Bool     // true면 호출측이 동작 차단
    let axElement: AXUIElement? // 쓰기 시 재사용
}

enum TextTargetService {
    static func captureContext() -> TargetContext
    static func insert(_ text: String, into context: TargetContext)
}
```

## 읽기 (captureContext)

1. `NSWorkspace.frontmostApplication` 로 앱 이름/번들 ID.
2. `AXUIElementCreateSystemWide()` → `kAXFocusedUIElementAttribute` 로 포커스 요소.
3. `kAXSubroleAttribute == kAXSecureTextFieldSubrole` → 보안 필드면 즉시 리턴 (selectedText/fullText nil, isSecureField=true, 클립보드 폴백 시도 안 함).
4. `kAXSelectedTextAttribute` (선택), `kAXValueAttribute` (전체) 읽기.
5. 둘 다 비었으면 클립보드 ⌘C 폴백 실행.

## 쓰기 (insert)

1. 보안 필드면 즉시 리턴 (하드 블록).
2. AX 시도: `AXUIElementSetAttributeValue(kAXSelectedTextAttribute, text)`. 성공하면 종료. (선택 있으면 교체, 없으면 캐럿 삽입 — 지원 앱 한정.)
3. 실패 시 클립보드 ⌘V 폴백.

## AX vs 클립보드 폴백 판정 로직

- **읽기 폴백 조건**: `kAXSelectedTextAttribute` 와 `kAXValueAttribute` 가 **둘 다** nil 또는 빈 문자열일 때만 ⌘C 주입. AX가 값을 하나라도 주면 폴백 안 함 (불필요한 클립보드 오염 방지).
- **쓰기 폴백 조건**: `AXUIElementSetAttributeValue` 반환값이 `.success` 가 아니면 ⌘V. AX가 실제로 텍스트를 넣었는지 별도 검증은 안 함 — success면 신뢰 (앱별 오동작 시 5단계 통합 후 실측으로 조정).
- **폴백은 보안 필드에서 절대 실행 안 됨** — captureContext/insert 진입 직후 isSecureField 가드.

## 클립보드 백업/복원

- `NSPasteboard.pasteboardItems` 의 **모든 아이템 × 모든 타입** 을 Data 로 스냅샷 → 복원 시 `NSPasteboardItem` 재구성. RTF/이미지/파일 등 비-string 클립보드도 보존.
- 읽기: changeCount 기준 폴링(최대 0.3s, 10ms 간격) 으로 ⌘C 반영 감지 후 읽고 복원.
- 쓰기: 텍스트 세팅 → ⌘V → 0.1s 대기(붙여넣기 소비 시간) → 복원.

## CGEvent 주입

- `CGEventSource(stateID: .privateState)` — HID 스트림이 아니라서 우리 앱의 전역 핫키 탭에 재유입되지 않음 (`.hidSystemState` 회피).
- keyDown/keyUp 페어, `⌘` 는 `CGEventFlags.maskCommand`.
- `post(tap: .cghidEventTap)` 로 시스템 큐 주입.
- 키코드: C=0x08, V=0x09.

## 보안 필드 처리 (하드 룰, 설정 아님)

- `kAXSecureTextFieldSubrole` 감지 시 captureContext 는 selectedText/fullText 를 강제 nil, isSecureField=true 리턴.
- insert 는 isSecureField true 면 아무 것도 안 함.
- 클립보드 폴백(⌘C/⌘V) 도 보안 필드에선 진입 자체가 차단됨 — 비밀번호가 클립보드로 새지 않음.

## 알려진 한계 (ponytail: 실측 후 조정)

- AX 쓰기 success 를 신뢰 (실제 삽입 여부 재확인 안 함). 앱이 success 를 주고도 무시하면 5단계에서 감지해 폴백 강제 옵션 추가.
- 폴링 타임아웃/딜레이(0.3s / 0.1s)는 고정값. 느린 앱에서 부족하면 조정 필요 — 물리적 튜닝 노브.

## 사용자 수동 확인 필요 (GUI 실측, 에이전트 불가)

AX 지원 편차는 앱별 실측으로만 확인 가능. 5단계 통합 후 각 앱에서:

### 읽기 (선택 텍스트 캡처)
1. **Safari** — 텍스트 필드/textarea 에서 텍스트 선택 후 핫키 → selectedText 채워지는지. contenteditable/리치 에디터는 AX 실패 가능 → 클립보드 폴백 동작 확인.
2. **Mail** — 본문(리치 텍스트) 선택 캡처. AX kAXSelectedText 지원 여부.
3. **VSCode** (Electron) — 에디터 선택. Electron 은 AX 빈약할 수 있음 → 클립보드 폴백 위주 예상.
4. **Slack** (Electron) — 메시지 입력창 선택/전체. 폴백 예상.

### 쓰기 (삽입/교체)
5. 위 4개 앱 각각에서: 선택 있는 상태로 insert → 선택 교체되는지. 선택 없이 캐럿만 → 캐럿 위치 삽입되는지.
6. AX 실패 앱에서 ⌘V 폴백이 올바른 위치에 붙는지, **클립보드 원상 복구** 되는지 (핫키 전 클립보드 내용이 그대로인지 확인 — 텍스트/이미지 모두).

### 보안 필드
7. Safari 로그인 폼 **비밀번호 칸** 포커스 후 핫키 → captureContext.isSecureField=true, 아무 텍스트도 캡처 안 됨. insert 시도해도 아무 것도 안 붙음. 클립보드도 안 건드림 확인.

### 자기 재유입
8. insert 의 ⌘V 주입이 우리 앱 전역 핫키(⌘⇧Space 등)를 재트리거하지 않는지 (⌘C/⌘V 는 핫키와 다른 키라 직접 충돌 없지만, .privateState 소스로 이중 안전장치).

## 검증 결과 (자동)

- `swift build` 성공 (경고 0). 다른 에이전트 파일(HotkeyManager/PromptPanel)과 동시 컴파일 OK.
