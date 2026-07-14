# 22 — focused-readonly-selection

증상 (실측): 카카오톡·Slack에서 채팅 메시지 텍스트 선택 + 핫키 → 결과 스트리밍이
끝나면 패널이 닫히고 자동 교체가 시도됨 (보기 전용이어야 하는데 편집+선택 흐름).
20·21의 "포커스 밖 선택" 수정과 별개 케이스 — 어제 Slack 실측이 통과했던 건
컴포저가 포커스를 쥔 경우였고, 이번엔 다른 경로였다.

## 근본 원인 (통합 로그 진단으로 특정)

**읽기 전용 메시지 뷰가 포커스를 갖고 선택을 직접 들고 있다.** 포커스 요소의
selectedText가 처음부터 비어 있지 않아 20·21의 분기(웹 영역 권위, 투기적 ⌘C)를
전부 건너뛰고 기본 반환 → `isEditableElement` 판정:

| 케이스 | role | settable value/selText | 기존 판정 |
|---|---|---|---|
| 카카오톡 메시지 버블 | AXTextArea | no / no | **editable 오판** (role 거부 목록에 없음) |
| 카카오톡 입력칸 | AXTextArea | YES / YES | editable (정상) |
| Slack 메시지 | AXGroup | no / no | **editable 오판** (〃) |
| Slack 컴포저 | AXTextArea | YES / YES (+AXEditableAncestor) | editable (정상) |

거부 목록 방식은 "요소에 선택이 있으면 편집 컨텍스트"를 암묵 가정했는데, 메시지
뷰(읽기 전용 NSTextView / Chromium 포커서블 그룹)가 이 가정을 깬다.

## 수정

`isEditableElement(_:hasSelection:)` — 요소가 선택을 직접 들고 있고
value·selectedText **둘 다 확정적으로**(.success + false) 쓰기 불가면 읽기 전용
뷰 = 보기 전용. 실측상 편집 필드는 전부 settable YES라 교체 흐름 회귀 없음.
AX 오류·불명은 기존대로 편집 가능(기본 방향 유지 — 하드 룰 그대로).
선택 없는 삽입 흐름은 이 규칙을 타지 않는다 (hasSelection=false).

부수: captureContext 분기별 NSLog 진단 추가 (텍스트 내용 무기록 — 길이만).
미지의 앱 오판 시 `log show --predicate 'process == "AnywhereLLM"'`가 유일한
단서라 유지. zsh에서 `log`는 빌트인과 충돌 — `/usr/bin/log` 사용.

## 검증

- `swift build` 경고 0, `make` 성공.
- GUI 실측 (사용자, 2026-07-15): 카카오톡 메시지 선택 → 보기 전용 유지·입력칸
  무접촉 ✓, 카카오톡 입력칸 선택 교체 ✓, Slack 메시지 선택 보기 전용 ✓,
  Slack 컴포저 선택 교체 ✓, 선택 없는 삽입 회귀 없음 ✓.
