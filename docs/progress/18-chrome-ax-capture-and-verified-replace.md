# 18 — chrome-ax-capture-and-verified-replace

17 이후 사용자 보고: 선택+빈 입력 전송은 해결. (1) 보기 전용(후자)은 그대로 고장,
(2) 입력칸에서 선택 → 교체 안 되는 문제 추가 발견.

## 진단 — 라이브 Chrome 실측 (chrome-devtools로 조작 + AX 프로브)

17의 거부 목록 휴리스틱 자체는 정확했다. 문제는 그 앞단:

1. **systemwide 포커스 질의가 Chrome에서 항상 실패** (kAXErrorCannotComplete
   -25204, AX 트리 하이드레이션 후에도). `AXUIElementCreateSystemWide()` 경유
   `kAXFocusedUIElementAttribute`만 쓰던 기존 `focusedElement()`는 Chrome에서
   영원히 nil → 선택 캡처·편집 판정 전부 불능 → 후자는 삽입 모드로 오라우팅,
   입력칸 선택도 캡처 실패. 같은 질의를 **frontmost 앱 요소**
   (`AXUIElementCreateApplication(pid)`) 경유로 하면 즉시 성공.
2. **Chromium 웹 콘텐츠 AX 트리는 클라이언트 질의를 감지해야 생성**된다.
   앱 요소에 `AXWindows` 질의를 던지면 ~250ms 내 하이드레이션 (실측).
   `AXManualAccessibility`는 Chrome 미지원(-25205, Electron 전용),
   `AXEnhancedUserInterface`도 미지원(-25208).
3. **Chromium의 setSelectedText는 success를 반환하고 조용히 무시한다**
   (textarea에 "REPLACED" 쓰기 → err 0 → 0.3초 후에도 value 무변경, 선택 유지).
   기존 insert()는 성공 코드만 믿고 반환 → ⌘V 폴백도 안 탐 → 교체 안 됨(증상 2).
4. 본문 선택 시 포커스 요소는 AXWebArea이고 **selectedText를 정상 노출**
   (settable 둘 다 false → 거부 목록 판정 정확). 요소만 얻으면 후자는 설계대로 동작.

## 변경

- `focusedElement(wakeIfNeeded:)`: systemwide → frontmost 앱 요소 폴백 →
  (켠 경우) AXWindows 질의 + AXManualAccessibility 설정 후 100ms×3 재시도.
  wake는 핫키 캡처 경로(captureContext)만 — typeText의 보안 필드 재확인은
  대기 없는 기본 경로 (스트리밍 flush마다 300ms 블로킹 방지).
- `setSelectedTextVerified`: 쓰기 후 50ms 대기 → value/selectedText가 실제로
  변했는지 확인. 무변경·검증 불능이면 실패 취급.
- `insert()`: AX 검증 실패 시 **typeText 폴백** — AX가 무시된 경우 대상의 선택이
  그대로 살아 있어 유니코드 타이핑이 선택을 자연 대체한다 (삽입 모드에서 검증된
  경로와 동일 메커니즘). ⌘V 폴백(`clipboardPasteFallback`)은 삭제 — paste 소비
  타이밍 의존(0.1s)으로 이미 한 번 사고 났던 경로(progress/15)라 재사용 안 함.

## 검증

- 라이브 Chrome 실측: 앱 요소 경유 캡처 성공(AXWebArea/AXTextArea/AXTextField),
  본문 선택 selectedText 노출, 거부 목록 판정 정확, setSelectedText 무시 재현,
  콜드 트리 AXWindows 웨이크 250ms. iTerm2 터미널은 편집 가능 판정(회귀 없음).
- `swift build` 경고 0, `swift test` 25/25, `make` 성공.
- GUI 실측 필요:
  1. Chrome/웹뷰 페이지 본문 선택 → 핫키 → 결과가 패널에 남는지 (첫 핫키부터.
     콜드 스타트 직후라면 캡처에 ~300ms 걸릴 수 있음).
  2. Chrome 입력칸에서 텍스트 선택 → 지시 → 교체되는지 (immediate 자동 교체,
     preview 확정 버튼 양쪽).
  3. 회귀: 네이티브 앱(메모 등) 교체/삽입 4경로, 터미널 무선택 삽입.
