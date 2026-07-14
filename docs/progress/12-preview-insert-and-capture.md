# 12 — preview-insert-and-capture

사용자 실측 피드백 4차 반영. 문제 3건: (1) preview 설정이 immediate와 똑같아 보임,
(2) 결과 완료 전 로딩 표시 없음, (3) 선택한 문장이 패널에 안 보임.

## 진단

세 증상은 한 원인으로 수렴 — **선택 캡처 실패 → 강제 삽입 모드**:
삽입 모드는 applyMode를 무시했고(=preview 켜도 즉시 타이핑), 패널을 숨겼고(=로딩 없음),
선택 미리보기 UI가 없다(=선택 문장 안 보임). 캡처가 실패하는 앱(웹뷰/Electron 일부)은
kAXSelectedTextRange(선택 범위)는 주면서 kAXSelectedText(선택 텍스트)를 비워 보낸다 —
기존 폴백은 full까지 비어야 발동해서 이 경우를 놓쳤다.

추가로, 삽입 모드가 applyMode를 무시하는 원설계(07) 자체가 사용자 기대와 어긋남.

## 수정

### 1. applyMode를 삽입 모드에도 적용 (07 설계 변경)

UX 분기 = 선택 유무 × applyMode:

| | preview (기본) | immediate |
|---|---|---|
| **선택 있음** | transcript 스트리밍 + "교체 (⌘⏎)" 버튼 | transcript 스트리밍 + 완료 시 자동 교체 |
| **선택 없음** | transcript 스트리밍 + **"삽입 (⌘⏎)" 버튼** (신규) | 패널 숨기고 실시간 타이핑 (기존) |

- `showsTranscriptUI = hasSelection || applyMode != "immediate"` 가 컨트롤러/뷰 공통 분기.
- 삽입 preview 확정은 기존 `apply()` 경로 재사용 — `TextTargetService.insert`가
  빈 선택(캐럿)에 삽입. multi-turn도 transcript 경로라 자동 지원.
- 스트리밍 중 스피너 + "…" 버블 = 로딩 표시 (문제 2 해결).
- 실시간 타이핑은 이제 "선택 없음 + immediate" 조합에서만.

### 2. 선택 캡처 강화 (`TextTarget.captureContext`)

`selectedText`가 비었을 때:
- **선택 범위 길이 > 0** (kAXSelectedTextRangeAttribute) → ⌘C 클립보드 폴백 (신규).
- 범위도 없고 full도 없음 (AX 완전 침묵) → ⌘C 폴백 (기존 유지).
- 범위 0 + full 있음 → 진짜 선택 없음, 폴백 안 함 — ⌘C가 줄 전체를 복사하는
  에디터(VS Code 등)에서 "선택 안 했는데 선택 모드" 오탐 방지.

## 수동 테스트 시나리오 (GUI 실측 필요)

전제: `make run` + 접근성 권한.

1. **삽입 preview (기본 설정)** — 선택 없이 핫키 → 프롬프트 ⏎ → 패널에 스피너+스트리밍
   표시 → 완료 후 "삽입 (⌘⏎)" 버튼 → 누르면 캐럿 위치에 삽입.
2. **삽입 immediate** — 설정을 "즉시 반영"으로 → 선택 없이 전송 → 기존대로 패널 숨고
   실시간 타이핑.
3. **선택 캡처 (문제 앱)** — 이전에 선택이 안 잡히던 앱에서 문장 선택 → 핫키 →
   패널 상단에 선택 미리보기 표시 + 교체 플로우.
4. **오탐 없음** — TextEdit에서 선택 없이 핫키 → 삽입 UX (선택 모드로 오인 안 함).
5. **선택 preview/immediate 구분** — 선택 후 preview: 교체 버튼 확정 / immediate: 자동 교체.

## 검증 결과 (자동)

- `swift build` 성공, 경고 0. `swift test` 16개 통과. `make` 성공.
