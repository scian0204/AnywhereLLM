# 15 — panel-anchor-and-preview-insert

미리보기 모드 버그 2건 (사용자 실측 보고):
1. 결과가 위로 올라가 화면에서 안 보임.
2. 확정 삽입이 안 됨.

## 1. 패널이 위로 자라는 문제

근본 원인: `PanelPositioner`는 패널을 캐럿 **아래**에 놓는다
(`origin.y = anchor.minY - size.height - 4`) — 열릴 때의 작은 크기(~120px) 기준.
NSWindow의 origin은 **좌하단**이라, 결과 스트리밍으로 NSHostingView가
(`.preferredContentSize`) 패널 높이를 늘리면 하단 고정 + **위로 성장** —
상단에 있는 결과 블록이 캐럿 위쪽/화면 밖으로 밀려난다.

수정 (`PromptPanel`):
- `anchorTopLeft()` — 위치 확정 시(AppDelegate) 좌상단 점을 앵커로 저장.
- `didResizeNotification` → 좌상단을 앵커로 되돌림 = 상단 고정, **아래로 성장**.
  화면 `visibleFrame` 밖이면 안으로 클램프.
- `didMoveNotification` → 드래그로 옮기면 앵커 갱신 (리사이즈 시 원위치 방지).

**1차 수정 실패 — 진짜 근본 원인 (사용자 재보고 "1번은 그대로"):**
`host.sizingOptions = [.preferredContentSize]`는 **contentViewController가 있는
창에서만 동작** — 이 패널은 `contentView` 직접 할당이라 창이 스트리밍 중
**아예 리사이즈되지 않았다**. didResize가 안 울리니 위 앵커 로직도 발동 무.
결과는 고정된 작은 창 안에서 ScrollView가 짓눌리고, 하단 자동 스크롤이
내용을 위로 밀어냄 — "위로 올라가 안보임" 증상과 일치.

2차 수정 (GeometryReader + PreferenceKey 측정): **역시 실패** ("여전히 똑같음").
원인: GeometryReader는 *실제 배치된* 크기를 잰다 — ScrollView는 유연해서 창이
준 좁은 높이에 맞춰 압축되므로, 측정값이 항상 현재 창 크기와 같아 리사이즈가
영원히 no-op (순환 제약).

**최종 수정 (헤드리스 실측으로 검증 후 적용):**
- 실측 1: `NSHostingView.fittingSize`는 창 제약과 무관한 이상 크기를 정확히
  반환 (460×328 — ScrollView 콘텐츠 280 캡 포함).
- 실측 2: `layout()` 오버라이드는 rootView 콘텐츠 교체 시 확실히 발동하고,
  그 시점 fittingSize가 갱신돼 있음 (2줄→40줄 교체 시 96→328).
- `PanelHostingView: NSHostingView<ConversationView>` — `layout()` 훅에서
  `fittingSize`를 `resizeToFit(contentSize:)`로 전달 (레이아웃 패스 중 창 프레임
  변경을 피하려 다음 틱으로 미룸). GeometryReader/PreferenceKey 플러밍 제거.
- `PromptPanel.resizeToFit(contentSize:)`: `frameRect(forContentRect:)` 환산,
  좌상단 앵커 유지 `setFrame` — 아래로 성장 + visibleFrame 클램프.
- 기존 didResize/didMove 앵커 옵저버는 안전망으로 유지.

## 2. 미리보기 확정 삽입 실패

`apply()`가 쓰던 `TextTargetService.insert` = AX `setSelectedText`
(웹뷰/Electron 등에서 .success 반환하며 조용히 무시되는 사례) → ⌘V 폴백
(paste 소비 대기 0.1초 — 느린 앱이면 클립보드 복원이 먼저 일어나 miss).

수정: 확정 경로를 선택 유무로 분기 —
- **교체(선택 있음)**: 기존 `insert` 유지 (AX가 선택 영역을 정확히 대체).
- **삽입(무선택)**: `typeText`(유니코드 키 이벤트 타이핑) — 즉시반영 삽입에서
  이미 검증된 경로. 클립보드 무접촉, AX 쓰기 미지원 앱에서도 동작.
  보안 필드 재확인은 typeText 내부 하드 룰 그대로.
- 포커스 복귀 지연 0.12 → 0.15초 (스트리밍 삽입과 동일 값으로 통일).

## 검증

- `swift build` 경고 0, `make` 성공. (LLMCore 무변경 — 테스트 영향 없음.)
- GUI 자동 검증 불가 — 아래 수동 시나리오.

## 수동 테스트 시나리오 (GUI 실측)

1. 미리보기 모드, 캐럿이 화면 중간일 때 긴 결과 생성 → 패널 상단 고정,
   아래로 늘어나며 결과 전체가 보임.
2. 캐럿이 화면 하단 근처 → 패널이 자라면 화면 아래로 안 뚫고 위로 밀려 들어옴.
3. 패널을 드래그로 옮긴 뒤 결과 생성 → 옮긴 위치 기준으로 아래로 성장.
4. 무선택 + 미리보기 → 삽입(⌘⏎) → 대상 텍스트박스 커서 위치에 결과 타이핑됨
   (이전에 안 되던 앱에서 확인).
5. 선택 + 미리보기 → 교체(⌘⏎) → 선택 영역이 결과로 대체 (기존 동작 회귀 없음).
