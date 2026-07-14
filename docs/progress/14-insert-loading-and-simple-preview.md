# 14 — insert-loading-and-simple-preview

사용자 개선 요청 2건:
1. 즉시 반영(삽입) 모드에서 첫 토큰이 타이핑되기 직전까지 로딩이 보여야 함.
2. 미리보기 화면은 대화형 UI가 아니라 결과만 간단히 표기해야 함.

## 1. 삽입 모드 로딩

기존: 전송 즉시 `onStreamingInsertStart`로 패널을 숨김 — LLM 첫 토큰까지
(콜드 모델 로드 시 ~10초) 사용자에게 아무것도 안 보였다.

변경 (`ConversationController.sendInsertTurn`):
- 패널 숨김 + 150ms 포커스 복귀 지연을 `beginTypingIfNeeded()`로 묶어
  **첫 가시 콘텐츠(ThinkTagFilter 통과 후 buffer 비어있지 않음) 직전**에 실행.
- 그 전까지 패널 유지 — `ConversationView.insertMode`에 `isStreaming` 시
  ProgressView + "생성 중…" 로딩 행 추가.
- 타이핑 시작 전 에러는 flush 금지 (`if typingStarted { flush() }`) —
  패널이 아직 key라서 flush하면 합성 키 이벤트를 패널이 먹는다 (progress/10 불변 유지).
- 취소 경로 불변: 대기 중 Esc/핫키 재입력 → CancellationError → 버퍼 드롭.
- Swift 6: Task 클로저 안 중첩 로컬 async 함수는 MainActor 격리를 상속하지
  않아 `@MainActor` 명시 필요했음.

## 2. 미리보기 결과 단건 표기

기존: Transcript UX가 user/assistant 대화 버블을 전부 렌더.

변경:
- `ConversationController.latestAssistantText` computed 추가 — 마지막
  assistant 응답만 노출. **multi-turn 히스토리는 내부적으로 그대로 유지**
  (추가 지시 전송 시 문맥 이어짐), 화면 표시만 단순화.
- `ConversationView`: `transcriptScroll`/`bubble` 삭제 → `resultView` —
  마지막 응답을 평문 블록(ScrollView, maxHeight 280, 스트리밍 중 하단
  자동 스크롤)으로 표시. 스트리밍 시작 전엔 "…".
- 선택+immediate 경로도 같은 뷰를 공유하므로 동일하게 단순 표기.

## 검증

- `swift build` 성공, `swift test` 25개 통과 (LLMCore 회귀 없음).
- GUI 자동 검증 불가 — 아래 수동 시나리오 필요.

## 수동 테스트 시나리오 (GUI 실측)

1. 삽입+즉시반영: 전송 → 패널에 "생성 중…" 스피너 유지 → 첫 토큰 도착 순간
   패널 숨김 + 대상 텍스트박스 타이핑 시작. (콜드 모델이면 로딩이 수 초 보여야 정상.)
2. 삽입+즉시반영 중 로딩 단계에서 Esc 또는 핫키 재입력 → 아무것도 타이핑되지 않음.
3. 미리보기 모드: 전송 → 결과가 버블 없이 단일 블록으로 스트리밍 → 완료 시
   삽입/교체(⌘⏎) 버튼. 추가 지시 전송 시 이전 문맥 반영된 새 결과로 교체 표시.
4. 서버 끔 상태에서 삽입+즉시반영 전송 → 로딩 후 에러가 패널에 표시, 타이핑 없음.
