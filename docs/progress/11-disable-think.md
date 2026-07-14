# 11 — disable-think

reasoning 모델(Qwen3.5, Gemma 4 등)의 생각(think) 과정을 요청 단계에서 끄는
설정 토글 추가. 기존 ThinkTagFilter는 출력 필터(사후)였고, 이건 요청 필터(사전) —
생각 토큰 자체를 안 만들게 해서 지연/토큰을 아낀다.

## 변경 요약

| 파일 | 변경 |
|------|------|
| `Sources/AnywhereLLM/SettingsView.swift` | LLM 섹션에 "생각(think) 모드 끄기" 토글 (`llm.disableThink`, 기본 꺼짐) |
| `Sources/AnywhereLLM/LLMClient.swift` | 켜지면 body에 `chat_template_kwargs: {enable_thinking: false}` 추가 |
| `Sources/AnywhereLLM/ConversationController.swift` | 켜지면 시스템 프롬프트 끝에 `/no_think` 추가 |

## 서버별 동작 (2026-07 조사)

| 서버 | 메커니즘 | 이 토글의 효과 |
|------|---------|---------------|
| vLLM / SGLang / llama.cpp server | `chat_template_kwargs.enable_thinking=false` (Qwen3.5 공식) | 완전 차단 |
| Ollama `/v1` (OpenAI 호환) | `think` 파라미터 미지원 (네이티브 API 전용, 알려진 갭) | `chat_template_kwargs` 무시됨 → `/no_think` 소프트 스위치(Qwen3 계열)만 효과. 출력은 ThinkTagFilter가 거름 |
| Qwen3 계열 | 소프트 스위치 `/no_think` | 효과 (Qwen3.5 대형은 소프트 스위치 미지원 — API 키워드만) |
| Gemma 4 | 시스템 프롬프트 `<|think|>` 토큰 유무로 제어 | 앱이 토큰을 안 넣으므로 기본 비활성. `-thinking` 변형은 가중치에 박혀 있어 완전 차단 불가 보고 있음 |
| OpenAI 등 미인식 서버 | 알 수 없는 파라미터에 400 가능 | 기본 꺼짐(옵트인)이라 영향 없음. 켜고 오류 나면 끄라고 캡션 안내 |

두 메커니즘(`chat_template_kwargs` + `/no_think`)을 함께 쓰는 이유: 단일 방식으로
모든 서버를 못 덮는다. 미지원 모델에게 `/no_think`는 무해한 텍스트.
ThinkTagFilter(출력 필터)는 설정과 무관하게 항상 동작 — 안전망 유지.

## 수동 테스트 시나리오 (GUI 실측 필요)

1. 설정 → "생각(think) 모드 끄기" 켬 → vLLM/llama.cpp 서버 + Qwen3.5에서
   삽입 모드 전송 → 응답 지연이 짧아지고 think 내용 없음.
2. 같은 설정으로 OpenAI(gpt-4o-mini) 전송 → 오류 발생 여부 확인 (400이면 토글 끄면 복구).
3. 토글 끈 상태 → 기존과 동일 동작 (요청 body에 chat_template_kwargs 없음).
4. Ollama에서 Qwen3 → 켜면 `/no_think`로 생각 생략되는지.

## 검증 결과 (자동)

- `swift build` 성공, 경고 0. `swift test` 16개 통과. `make` 성공.
