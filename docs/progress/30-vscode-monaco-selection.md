# 30 — vscode-monaco-selection

버그: VS Code에서 텍스트 선택 후 핫키 → 패널은 뜨는데 선택이 캡처되지 않음
(삽입 모드로 처리). 사용자 실측 로그:

```
capture: app=com.microsoft.VSCode role=AXTextArea selLen=0 rangeLen=0 fullLen=0
capture: webArea found, webSelLen=nil
capture: default return editable=1 selPresent=0
```

## 원인 — Monaco는 선택을 AX에 노출하지 않는다

VS Code(Monaco) 에디터의 실제 입력 요소는 히든 textarea. CLI 프로브로 실측
(⌘A로 진짜 선택을 만든 상태):

- 히든 textarea: `selLen=0`, `rangeLen=0` — 선택이 있어도 항상 0.
- 조상 AXWebArea의 `selectedText`: nil — Monaco 선택은 DOM 선택이 아니라
  렌더링된 div (웹 영역 권위 규칙(progress/20)이 닿지 않음).
- 유일한 신호는 ⌘C인데, 웹 계열 경로는 progress/21에서 ⌘C를 의도적으로 금지 —
  빈 선택 ⌘C = 현재 줄 복사(emptySelectionClipboard)라 phantom 선택 오탐이
  생기기 때문. 이 규칙이 진짜 선택까지 삼키고 있었다.

참고 — VS Code AX는 하이드레이션 단계별로 다르게 보인다 (모두 실측):

1. 신선한 프로세스: 포커스 요소 자체가 nil → 기존 nil-경로 ⌘C가 잡긴 함 (보기 전용).
2. wake(AXManualAccessibility) 이후: textarea는 보이는데 선택 속성은 전부 빈 값
   — **사용자가 겪은 상태이자 이 수정의 대상**.
3. AXEnhancedUserInterface(VoiceOver 상당)까지 켠 뒤: textarea가 선택을 직접
   노출 → 기존 코드로도 동작. 단 이 플래그는 VS Code를 스크린리더 모드로
   전환시켜 사용자 에디터 동작이 바뀌므로 앱이 켜는 건 부적절.

## 수정 — 클립보드 메타데이터로 phantom 판별

VS Code는 ⌘C마다 클립보드에 vscode-editor-data JSON을 남긴다
(`org.chromium.web-custom-data` 플레이버, UTF-16LE 인코딩):

- 진짜 선택 복사: `"isFromEmptySelection":false`
- 빈 선택 줄 복사: `"isFromEmptySelection":true`

→ 웹 영역이 "선택 없음"일 때 ⌘C 프로브(0.15s)를 쏘되, **메타데이터가
`isFromEmptySelection":false`를 확정할 때만** 결과를 채택한다. 메타데이터가
없거나(일반 웹 앱, Google Docs, CodeMirror류) `true`면 폐기 — progress/21의
줄 복사 오탐 차단은 그대로 유지된다.

채택된 선택은 포커스 요소 소속으로 취급 (Slack류 "포커스 밖 선택"과 달리
에디터 자신이 선택을 쥐고 있다) → editable=true + 선택 있음 = Transcript UX,
교체는 기존 CGEvent 타이핑 경로 (⌘C 프로브는 선택을 죽이지 않으므로 살아있는
선택이 그대로 대체됨).

`clipboardCopyFallback`에 `requireWebEditorSelectionMetadata` 파라미터 추가
(기본 false — 기존 호출부 무영향).

## 트레이드오프 (의도)

- 웹 계열 + 선택 못 찾음 캡처에 ⌘C 프로브 최대 0.15s 추가 (실측: VS Code
  선택 46ms, 빈 선택 31ms — 클립보드 변경이 없을 때만 풀 타임아웃). progress/21이
  없앴던 웹 앱 빈 입력칸 ⌘C 지연이 절반(0.3→0.15s)으로 부활한 셈 — 선택 캡처
  기능과 맞바꾼 의도된 비용.
- 메타데이터 없는 웹 에디터(Google Docs, CodeMirror/Obsidian류)의 AX 미노출
  선택은 여전히 미탐 — 오탐(줄 복사 승격)보다 안전한 방향. 판별자가 생기면 추가.
- VS Code 통합 터미널 선택은 메타데이터가 없어 미탐 (기존과 동일).
- 프로브 ⌘C의 부작용 (수용): ① 줄 복사 에디터에서 선택 없이 핫키를 누르면 현재
  줄이 복원 전 잠깐(수십 ms) 클립보드에 실린다 — 클립보드 히스토리 도구(Maccy류)가
  그 순간을 기록할 수 있음. ⌘C 프로브 방식에 내재된 비용 (기존 네이티브/nil-요소
  프로브와 동일 부류). ② 커스텀 복사 핸들러를 가진 웹 앱(Figma 등)은 "복사됨"
  토스트 등 가시 반응을 보일 수 있음. ③ 복사 반영이 타임아웃(0.15s)보다 늦게
  도착하면 복원된 클립보드를 덮는 레이스 — 잔여물이 웹 에디터 메타데이터를 달고
  있으므로 0.3s 후 재확인해 재복원. ⌘C가 무반응이면(클립보드 무변경) 복원 자체를
  생략해 changeCount churn도 없앰.
- VS Code 읽기 전용 에디터(diff 뷰 왼쪽 등)의 선택도 메타데이터가 false로 나와
  editable로 채택됨 — immediate 모드 자동 교체가 읽기 전용 에디터에 막혀 결과가
  유실될 수 있음 (알려진 한계, Chromium AX가 읽기 전용을 구분해주지 않음.
  사례 나오면 재검토).

## 검증

- `swift build` 경고 0, `swift test` 25/25, `make` 성공.
- E2E 실측 (CLI로 합성 키 입력 + 통합 로그 확인):
  1. VS Code 진짜 선택 + 핫키 → `web editor metadata probe (len 3)` →
     `selPresent=1 editable=1`. ✅
  2. VS Code 선택 없음 + 핫키 → 프로브가 줄 복사 폐기 (`len -1`) →
     `selPresent=0` 삽입 모드. ✅ (progress/21 회귀 없음)
  3. Chrome 본문 포커스 + 핫키 → 새 분기 미진입 (포커스가 AXWebArea 자신 →
     조상 웹 영역 없음), 기존 경로 그대로. ✅
- 사용자 실측 필요: VS Code에서 선택 → 핫키 → 교체 플로우 끝까지 (프리뷰
  확정/immediate 자동 교체가 선택을 실제로 대체하는지), Cursor 등 포크에서도
  동작하는지.
