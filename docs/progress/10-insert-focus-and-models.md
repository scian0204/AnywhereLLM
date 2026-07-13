# 10 — insert-focus-and-models

사용자 실측 피드백 3차 반영: 삽입 모드 타이핑이 대상 앱에 안 들어가던 버그 수정,
모델 가져오기(BaseUrl 기준 /models)가 로컬 서버에서 실패하던 문제 수정.

## 변경 요약

| 파일 | 변경 |
|------|------|
| `Sources/AnywhereLLM/ConversationController.swift` | 삽입 스트리밍 시작 훅 + 150ms 포커스 반환 대기 + 취소 시 버퍼 드롭 + 에러 훅 |
| `Sources/AnywhereLLM/PromptPanel.swift` | 스트리밍 시작 시 패널 숨김, 에러 시 재표시, present()가 이전 세션 취소, 콜백 identity 가드 |
| `Sources/AnywhereLLM/LLMClient.swift` | API 키 선택화(로컬 서버), joinEndpoint 사용, URL 강제 언래핑 제거, `missingAPIKey`→`invalidBaseURL` |
| `Sources/LLMCore/Endpoint.swift` | 신규 — `joinEndpoint(base:path:)` 끝 슬래시/공백 정규화 (순수, 테스트 가능) |
| `Tests/LLMCoreTests/EndpointTests.swift` | 신규 — 4 케이스 |
| `Sources/AnywhereLLM/ConversationView.swift` | 삽입 모드 "생성 중" UI 제거 (패널이 숨어 그릴 기회 없음 — 죽은 코드) |
| `Sources/AnywhereLLM/TextTarget.swift` | typeText 주석 정정 + 타이핑 직전 보안 필드 재확인 |
| `Sources/AnywhereLLM/AppDelegate.swift` | 핫키로 패널 숨길 때 스트림도 취소 (`panel.dismiss()`) |

## 버그 1 — 삽입 모드: 생성 텍스트가 대상에 입력 안 됨

### 근본 원인

07 문서의 가정 "패널이 non-activating이라 대상 앱이 포커스를 유지 → 타이핑 이벤트가
대상 텍스트박스에 꽂힘"이 틀렸다. `.nonactivatingPanel`은 **앱을 activate 하지 않을 뿐,
패널 자신은 key window가 된다** (사용자가 패널에 타이핑할 수 있는 이유가 바로 이것).
window server는 합성 키 이벤트(`cghidEventTap` post)를 key window로 라우팅하므로,
스트리밍 중 `typeText`의 이벤트는 대상 앱이 아니라 **패널이 먹었다**. 스트리밍 중엔
입력창도 숨겨져 있어 문자가 그냥 증발.

선택 모드는 `apply()`가 `orderOut` → 0.12s 대기 → 삽입이라 정상이었다. 삽입 모드만
패널을 띄운 채 타이핑해서 실패.

### 수정

선택 모드와 같은 패턴으로 통일:

1. `sendInsertTurn` 시작 시 `onStreamingInsertStart` → 패널 `orderOut` (key 반환).
2. 스트리밍 Task는 타이핑 전 150ms 대기 (포커스가 대상 앱으로 돌아올 시간).
3. 완료 시 기존대로 세션 정리. 에러 시 `onStreamingInsertError` → 패널 재표시 (메시지 노출).
4. 패널이 숨어 있으니 Esc 취소 불가 → **핫키 재입력이 취소 수단**:
   `present()`가 이전 controller를 `cancel()` 하고 새 세션을 연다.
5. 취소 시 남은 버퍼는 타이핑하지 않고 버림 — 새 패널이 이미 key라 오입력 위험.
6. done/error 콜백에 `self.controller === controller` identity 가드 — 취소로 교체된
   옛 세션이 새 패널을 닫는 레이스 차단.

## 버그 2 — 모델 가져오기 실패

BaseUrl 기준 `GET {base}/models` → 드롭다운 표시 자체는 구현되어 있었으나:

- **API 키 필수 가드**가 키 없는 로컬 서버(Ollama, LM Studio 등)를 원천 차단 →
  키 있으면 Bearer 헤더 추가, 없어도 요청은 나가게 변경 (chat completions도 동일).
  키 없이 OpenAI 호출 시엔 서버의 401 메시지가 그대로 표시됨.
- Base URL 끝 슬래시(`…/v1/`) 시 `…/v1//models` — `joinEndpoint`로 정규화.
- `URL(string:)!` 강제 언래핑 → 잘못된 입력에서 크래시 가능 → `invalidBaseURL` 에러로 전환.

## 적대적 리뷰에서 잡은 추가 결함 (같은 커밋에서 수정)

멀티에이전트 리뷰(3관점 + 지적별 반박 검증)로 확인된 HIGH 3건:

1. **취소가 nil-종료로 옴** — `AsyncThrowingStream`은 소비 태스크가 `next()` 대기 중
   취소되면 CancellationError를 던지지 않고 nil로 정상 종료한다. post-loop flush가
   취소 확인 없이 실행되어 잔여 버퍼(≤100ms 분량)가 그 시점의 key window(핫키 재입력으로
   방금 뜬 새 패널 입력창)에 타이핑됨. → 루프 직후 `try Task.checkCancellation()` 추가.
2. **선택 모드 취소 누수** — `present()`의 cancel이 선택 모드 태스크도 취소하는데
   `finishSelectStreaming`에 취소 가드가 없어 immediate 모드에서 부분 텍스트를 적용하고,
   `onApply`에 identity 가드가 없어 옛 세션이 새 패널을 닫아버림. → `!Task.isCancelled`
   가드 + `onApply`에도 identity 가드. 핫키로 패널을 숨기는 분기도 `dismiss()`(취소 포함)로 통일.
3. **보안 필드 TOCTOU** — 캡처 시점 검사 후 스트리밍 수 초 사이 사용자가 비밀번호 필드로
   포커스를 옮길 수 있음. 패널을 숨기는 이번 수정으로 합성 이벤트가 실제 포커스 요소에
   닿게 되면서 노출이 실제화. → `typeText`가 flush마다 포커스 요소 subrole을 재확인,
   보안 필드면 드롭 (하드 룰 집행 지점을 타이핑 계층으로 내림).

미수정 (경미, 기록만): 에러로 패널 재표시 시 입력창 키보드 포커스 미복원(클릭 필요),
키 없이 OpenAI 호출 시 영어 401 본문 노출(로컬 서버 지원 트레이드오프).

## 수동 테스트 시나리오 (GUI 실측 필요)

전제: `make run` + 접근성 권한.

1. **삽입 모드 타이핑** — TextEdit 캐럿만 두고 핫키 → 프롬프트 ⏎ → 패널이 사라지고
   응답이 TextEdit에 실시간 타이핑 → 완료 후에도 패널 안 뜸.
2. **삽입 모드 취소** — 긴 응답 생성 중 핫키 재입력 → 타이핑 즉시 중단, 새 패널 열림.
3. **삽입 모드 에러** — Base URL을 틀리게 설정 후 전송 → 패널이 다시 나타나며 에러 표시.
4. **선택 모드 회귀 없음** — 텍스트 선택 후 핫키 → 기존 UI(미리보기+transcript+교체) 동작.
5. **모델 가져오기 (키 없음)** — Base URL을 로컬 서버(예: `http://localhost:11434/v1`)로,
   API 키 비운 상태에서 "모델 가져오기" → 드롭다운에 모델 목록.
6. **모델 가져오기 (끝 슬래시)** — Base URL 끝에 `/` 붙여도 동일 동작.
7. **보안 필드 차단 유지** — 비밀번호 필드에서 핫키 → 패널 안 뜨고 경고 (기존 동작).

## 검증 결과 (자동)

- `swift build` 성공, 경고 0.
- `swift test` 16개 통과 (SSEParser 5 + ThinkTagFilter 7 + Endpoint 4).
- `make` (release + 서명) 성공.
