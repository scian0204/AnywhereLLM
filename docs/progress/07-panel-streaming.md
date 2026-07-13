# 07 — panel-streaming

사용자 실측 피드백 2차 반영: `<think>` 태그 제거, 패널 UX 모드별 재설계,
삽입 모드 실시간 스트리밍 타이핑.

## 변경 요약

| 파일 | 변경 |
|------|------|
| `Sources/LLMCore/ThinkTagFilter.swift` | 신규 — 상태형 `<think>…</think>` 제거 필터 (순수, 테스트 가능) |
| `Tests/LLMCoreTests/ThinkTagFilterTests.swift` | 신규 — 7 케이스 |
| `Sources/AnywhereLLM/TextTarget.swift` | `typeText(_:)` 추가 — CGEvent 유니코드 타이핑 (클립보드 미사용) |
| `Sources/AnywhereLLM/ConversationController.swift` | 삽입/선택 모드 분리, 필터 적용, 삽입 모드 실시간 타이핑 |
| `Sources/AnywhereLLM/ConversationView.swift` | 모드별 레이아웃 (삽입=입력창만 / 선택=기존 UI) |
| `Sources/AnywhereLLM/PromptPanel.swift` | `onStreamingInsertDone` 훅 (삽입 완료 시 패널 닫기) |

## `<think>` 필터 상태 기계 (ThinkTagFilter)

스트리밍 청크 경계에 태그가 걸쳐도 동작하도록 상태를 유지한다. `feed(chunk)`는
지금까지 노출 가능한 텍스트를 반환, 스트림 끝에 `flush()`로 보류분을 방출.

상태:
- `insideThink: Bool` — 현재 `<think>` 블록 안인지.
- `pending: [Character]` — 태그의 접두사일 수 있어 보류 중인 꼬리 텍스트.

`feed` 루프 (pending 소진할 때까지):
1. 현재 찾는 태그 = insideThink ? `</think>` : `<think>`.
2. **완전 매치** 있으면: (밖일 때만) 매치 앞 텍스트 방출 → 매치까지 제거 → insideThink 토글. 계속 루프.
3. 완전 매치 없지만 **꼬리가 태그 접두사** (`…<thi`)면: 그 꼬리만 보류, 나머지는 (밖일 때) 방출하고 종료.
4. 둘 다 아니면: (밖일 때) 전부 방출, pending 비움, 종료.

`flush()`: insideThink면 빈 문자열(안 닫힌 블록은 끝까지 drop), 아니면 남은 pending 방출.

한계 (ponytail): 리터럴 `<think>`/`</think>` 만 인식(대소문자 구분). 현재 reasoning
모델 출력 형식에 맞춤. 다른 변형 태그는 미지원.

검증: 7 케이스 통과 — think 없음 / 한 청크 완결 / 청크 경계 분할 / 안 닫힘(끝까지 drop) /
부분 매치가 실제로는 태그 아님(`<then`) / 다중 블록 / `<` 단독(`1 < 2`).

## 실시간 스트리밍 삽입 (typeText)

`TextTargetService.typeText(_:)`:
- `CGEventKeyboardSetUnicodeString` 로 유니코드 문자열을 keyDown/keyUp 페어에 실어 주입.
  가상 키코드 0 사용 — 실제 키가 아니라 유니코드 문자열 전달.
- UTF-16 단위 20개씩 청크 (긴 문자열은 API가 잘라먹으므로). **클립보드 미사용** — 붙여넣기 오염 없음.
- `CGEventSource(.privateState)` — 우리 핫키 탭에 재유입 안 됨 (기존 sendKey와 동일 안전장치).
- 패널이 non-activating이라 대상 앱이 포커스를 유지 → 타이핑 이벤트가 대상 텍스트박스에 꽂힘.

기존 `insert(_:into:)` 는 선택 모드 교체용으로 그대로 유지 (AX 우선 + 클립보드 ⌘V 폴백).

## 모드별 동작표

| | **삽입 모드** (선택 없음) | **선택 모드** (선택 있음) |
|---|---|---|
| 패널 UI | 입력창 하나만 | 선택 미리보기 + transcript + 입력창 + 교체 버튼 |
| ⏎ 전송 후 | 응답이 대상 텍스트박스에 실시간 타이핑 | transcript에 스트리밍 표시 |
| 타이핑 메커니즘 | `typeText` (CGEvent 유니코드, ~100ms 버퍼 flush) | 화면 표시만, 확정 시 `insert` |
| `<think>` 필터 | 적용 (타이핑 전) | 적용 (표시 전) |
| 스트리밍 중 표시 | "생성 중… (Esc 취소)", 입력창 숨김 | 스피너 + transcript 갱신 |
| Esc | Task 취소 (이미 타이핑된 건 그대로) | Task 취소 (부분 텍스트 유지) |
| 완료 시 | 패널 자동 닫힘 | preview=교체 버튼 / immediate=자동 교체 |
| multi-turn | 없음 (단발) | 있음 (패널 열린 동안 히스토리 유지) |
| `applyMode` 설정 | **무시** (항상 실시간 스트리밍) | 적용 (preview/immediate) |

**applyMode 관계 (명시)**: 삽입 모드는 항상 실시간 스트리밍이라 `applyMode`를 무시한다.
`applyMode`는 선택 모드에만 적용 — `preview`(기본)=교체 버튼 확정, `immediate`=완료 시 자동 교체.

## 수동 테스트 시나리오 (GUI 실측)

전제: `make run` + 접근성 권한 + Keychain 유효 API 키.

1. **삽입 모드 실시간 타이핑** — TextEdit 캐럿만 두고 ⌘⇧Space → 입력창만 있는 작은 패널.
   "짧은 인사말 써줘" ⏎ → "생성 중…" 표시되며 응답이 TextEdit에 글자 단위로 타이핑됨 → 완료 시 패널 자동 닫힘.
2. **think 필터** — reasoning 모델(예: deepseek-r1 등) 설정 후 삽입/선택 모드 각각에서
   `<think>` 내용이 화면/타이핑에 안 나오고 최종 답변만 나오는지.
3. **선택 모드 유지** — 문장 선택 후 ⌘⇧Space → 기존 UI(미리보기+transcript+교체 버튼), multi-turn 동작.
4. **삽입 모드 Esc 취소** — 타이핑 중 Esc → 스트림 중단, 이미 입력된 부분은 남고 패널 닫힘.
5. **삽입 모드 클립보드 무오염** — 타이핑 전 클립보드에 뭔가 복사 → 삽입 모드 사용 후 클립보드 그대로인지 (typeText는 클립보드 미사용).
6. **에러** — 키 없이 삽입 모드 전송 → "생성 중" 후 에러 텍스트 표시, 패널 유지(자동 안 닫힘).
7. **긴 응답 정확도** — 20자 넘는 유니코드/한글 응답이 누락/중복 없이 그대로 타이핑되는지 (청크 경계 검증).

## 검증 결과 (자동)

- `swift build` 성공, 경고 0.
- `swift test` 12개 통과 (SSEParser 5 + ThinkTagFilter 7).
- `make` 성공.
