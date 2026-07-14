# 17 — view-only-and-prompt-only-send

사용자 보고: 원 설계는 "편집 가능 필드 포커스 = 입력 목적 / 아니면 선택 텍스트에 대한
결과 보기 목적"인데 후자가 고장. 요구 3건:
1. 편집 불가 대상에서 결과를 보여주는 창이 (모드와 무관하게) 남아야 함.
2. 전자(입력 목적)는 그대로 유지.
3. 선택이 있으면 추가 입력 없이 프롬프트(프로필)만으로 요청 가능해야 함.

## 원인

앱에 "편집 가능성" 개념이 없었다. 선택만 있으면 무조건 교체 흐름:
- immediate: 완료 시 `onApply` → 패널 닫고 교체 시도 → 편집 불가 대상이라 실패,
  결과는 패널과 함께 소실.
- preview: "교체" 버튼이 뜨지만 눌러도 들어갈 곳이 없음 (typeText가 비텍스트 앱에
  키 이벤트를 쏘는 오동작 위험까지).

## 변경

- `TargetContext.isEditable` 추가. `isEditableElement` 판정은 **거부 목록** 방식:
  1) `kAXValueAttribute`/`kAXSelectedTextAttribute` settable이면 true (contenteditable
     AXWebArea가 거부 목록에 걸리지 않도록 role 검사보다 먼저),
  2) 콘텐츠 표시 전용 role(AXWebArea·AXStaticText·AXImage·AXScrollArea·AXList·
     AXOutline·AXTable·AXBrowser)이면 false,
  3) 그 외 불명·AX 오류·포커스 요소 없음은 전부 true.
  근거: 오탐(편집 가능 오판)은 기존 동작과 동일해 무해, 미탐(편집 필드를 보기 전용
  오판)은 삽입 회귀라 치명적. CGEvent 타이핑/⌘V 쓰기는 AX가 아예 필요 없으므로
  AX 침묵 앱(Electron 하이드레이션 전, 원격 데스크톱, 접근성 브리지 꺼진 Java)도
  true여야 기존 흐름이 유지된다. 처음엔 허용 목록(role+settable OR)으로 짰다가
  적대 검증에서 반전 — 검증 에이전트가 콜드 스타트 Chrome에서 focusedElement가
  하이드레이션 전 ~9초간 nil임을 실측 재현했다 (허용 목록이면 그동안 삽입 전면 회귀).
- focusedElement가 nil이면 대상 앱에 `AXManualAccessibility=true`를 fire-and-forget
  으로 설정 — Chromium/Electron이 접근성 트리를 만들도록 유도해 다음 핫키부터
  선택 캡처가 가능해진다 (대기 없음, 미지원 앱엔 무해한 오류).
- `ConversationController.isViewOnly` (= `!context.isEditable`):
  - `showsTranscriptUI`에 포함 — 보기 전용은 선택 유무·모드 무관 transcript UX.
  - `finishTranscriptStreaming`: 보기 전용이면 `onApply`/`pendingResult` 모두 스킵 —
    결과가 패널에 남고 확정 버튼도 안 뜬다. 닫기는 Esc/핫키.
  - `systemContent`: 보기 전용이면 "패널로 표시됩니다. 간결하고 정확하게" 지시
    (교체·삽입용 "텍스트만 출력" 제약은 보기 목적에 부적합).
- 빈 입력 전송: `send()` 가드를 "선택 있음 + 첫 턴 + **프로필 프롬프트 비어있지 않음**"
  이면 빈 입력 허용으로 완화. 프로필 조건은 적대 검증 지적 반영 — 프로필까지 비면
  지시가 전무한 요청이고, immediate 모드에선 무지시 응답이 선택을 자동 교체해버리는
  오입력 ⏎ 함정이 된다. `userContent`는 입력이 비면 `[요청]` 섹션 생략.
- 토큰 0개로 끝난 턴(에러/무응답)은 user+assistant 쌍을 transcript에서 제거 —
  빈 assistant 메시지가 다음 턴 prior로 전송되는 것과, 첫 턴 실패 후 빈 ⏎ 재시도가
  첫 턴 가드에 막히는 것을 방지 (적대 검증 지적).
- 부수 수정: `buildMessages` 제거, transcript에 접은 본문(`[선택한 텍스트]` 포함)을
  저장 — 기존엔 raw input만 저장돼 **멀티턴 2번째 턴부터 선택 텍스트가 prior에서
  유실**됐다. 화면은 assistant 결과만 그리므로 표시 무영향.

## 검증

- `swift build` 경고 0, `swift test` 25/25.
- diff 적대 검증 워크플로 (관점 3개 리뷰 → 지적 8건 → 반박 검증으로 5건 확정):
  nil 요소 보기 전용 회귀(critical, Chrome 콜드 스타트 실측 재현), settable 오류를
  편집 불가 증거로 오독(major), 프로필 없는 빈 ⏎ immediate 자동 교체 함정(minor),
  빈 턴 잔재로 재시도 차단(minor) — 전부 반영. 멀티턴 prior 변경은 의도된 개선으로
  확인 (includeFullText 사용 시 후속 턴 토큰 증가는 허용 범위).
- GUI 실측 필요 (자동 검증 불가):
  1. 웹페이지 본문 텍스트 선택(입력 필드 아님) → 핫키 → 지시 입력 or 빈 ⏎ →
     결과가 패널에 남는지, immediate/preview 양쪽 모두. 확정 버튼 없어야 함.
  2. PDF(미리보기 앱)·Finder에서 동일. Chrome은 콜드 스타트 직후 첫 핫키가 선택을
     못 잡을 수 있음(AX 트리 미생성) — 두 번째 핫키부터 정상이면 설계대로.
  3. 회귀: 에디터/메모 등 편집 필드에서 선택→교체, 무선택→삽입(immediate 타이핑,
     preview 확정) 4경로 전부 기존대로. 터미널(iTerm2/Terminal) 무선택 삽입 포함.
  4. 편집 필드에서 선택 + 빈 ⏎ → 프로필 프롬프트만으로 교체 흐름 동작.
     프로필이 빈 문자열이면 빈 ⏎이 무시되는지.
