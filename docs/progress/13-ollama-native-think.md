# 13 — ollama-native-think

think 끄기(11)가 Ollama에서 안 먹는 문제의 완결. 사용자 실서버
(`http://192.168.5.182:11434/v1`, gemma4:e2b-it-qat)로 실측한 결과를 근거로,
Ollama 감지 시 네이티브 `/api/chat` + `think:false`로 자동 전환한다.

## 실측 근거 (Ollama 0.31.2)

| 요청 | reasoning 생성 |
|------|---------------|
| `/v1` + `chat_template_kwargs` + `/no_think` (11의 방식) | 그대로 생성 (3,483자) |
| `/v1` + `think:false` | 그대로 생성 (3,796자) — `/v1`이 키 무시 |
| **네이티브 `/api/chat` + `think:false`** | **0자, content 즉시** (eval 0.12초) |

부가 발견: Ollama `/v1`은 생각을 `delta.reasoning` 별도 필드로 보낸다 —
`delta.content`만 읽는 앱에는 원래 안 새지만, 생각이 끝날 때까지 content가
시작되지 않아 첫 글자 지연이 수십 초였다.

## 변경 요약

| 파일 | 변경 |
|------|------|
| `Sources/LLMCore/OllamaChatParser.swift` | 신규 — 네이티브 NDJSON 라인 파서 (thinking 버림, content만) |
| `Sources/LLMCore/Endpoint.swift` | `endpointOrigin` 추가 — base URL에서 scheme://host:port 추출 |
| `Tests/LLMCoreTests/OllamaChatParserTests.swift` | 신규 — 파서 5 + origin 4 케이스 |
| `Sources/AnywhereLLM/LLMClient.swift` | think 끄기 ON일 때 `GET {origin}/api/version`으로 Ollama 감지(2초 타임아웃) → 네이티브 `/api/chat` + `think:false` 스트리밍. 요청 빌드를 static으로 정리. 에러 파싱에 Ollama 형태(`{"error":"…"}`) 추가 |
| `Sources/AnywhereLLM/SettingsView.swift` | 캡션에 "Ollama는 네이티브 API로 자동 전환" 명시 |

동작 규칙:
- **감지·전환은 think 끄기가 켜진 요청에서만** — 꺼져 있으면 기존 `/v1` 경로 그대로, 프로브 비용 0.
- 감지 실패(2초 타임아웃/404/비 Ollama)면 기존 `/v1` + `chat_template_kwargs` 폴백.
- 트레이드오프: think 끄면 어려운 문제 정확도 하락 가능 (실측: 강 건너기 문제
  생각 켬 "7회" 정답 / 초기 테스트에서 끔 "3회" 오답 사례. 단답·글쓰기 용도엔 무영향).

## 검증

- `swift test` 25개 통과 (기존 16 + OllamaChatParser 5 + endpointOrigin 4).
- `swift build` 경고 0, `make` 성공.
- **실서버 E2E**: `/api/version` → `{"version":"0.31.2"}` 감지 OK.
  앱과 동일한 네이티브 요청 → thinking 0자, content 즉시 스트리밍
  (`"7번"`, eval 0.12초 — 이전 /v1 대비 생각 3.5k자 대기 제거).

## 수동 테스트 시나리오 (GUI 실측)

1. 설정: Base URL `http://192.168.5.182:11434/v1`, 모델 gemma4:e2b-it-qat,
   "생각(think) 모드 끄기" 켬 → 삽입/선택 모드 전송 → 첫 글자가 수 초 내 시작
   (모델 로드 후엔 즉시).
2. 토글 끔 → 기존 `/v1` 경로 (생각 생성됨, 화면엔 안 보임, 첫 글자 지연 큼).
3. vLLM 등 비 Ollama 서버 + 토글 켬 → `chat_template_kwargs` 경로 유지.
