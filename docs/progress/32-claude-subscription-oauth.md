# 32 — Claude 구독 연동 (`claude setup-token` OAuth)

## 배경

`claude setup-token`은 Claude Pro/Max 구독자가 발급하는 장기(~1년) **셋업 토큰**
(`sk-ant-oat01-…`)을 출력한다. 이 토큰으로 Anthropic Messages API를 호출하면 별도
종량제 API 키 없이 구독으로 추론을 쓸 수 있다. 사용자가 이 토큰으로 동작하는 기능을
요청 → OpenAI 호환 경로 옆에 Anthropic OAuth 경로를 추가.

> 주의: 구독 토큰을 Claude Code 외부 도구에서 쓰는 것은 Anthropic 약관상 회색지대다.
> 사용자 본인 토큰·본인 책임. 기능은 옵트인(토큰을 넣어야만 동작).

## 설계 결정

- **접두사 자동 감지, 새 토글 없음.** 키가 `sk-ant-oat01-`로 시작하면 OAuth 경로로 분기.
  사용자는 기존 API 키 필드에 셋업 토큰을 붙여넣기만 하면 된다. 설정 UI/UserDefaults 키
  추가 0 (ponytail: 최소 표면).
- OAuth 경로는 설정의 **Base URL·Ollama 판별·disableThink를 무시**하고 항상
  `https://api.anthropic.com/v1/messages`로 간다. 상호 배타적.
- 순수 로직(판별·정규화·모델 해석·SSE 파싱)은 `LLMCore` ↔ `AnywhereLLM.Core`에
  동일 동작 + 동일 테스트로 분리 (기존 SSEParser/OllamaChatParser와 같은 기준).

## 셋업 토큰 API 요구사항 (틀리면 즉시 거부)

출처: 커뮤니티 통합 가이드(OpenClaw 방식) 실측 정리. 핵심:

1. **인증**: `Authorization: Bearer <token>` (x-api-key 아님).
2. **헤더** (Claude Code 호환 클라이언트로 식별 — 하나라도 빠지면 거부/401):
   - `anthropic-beta: claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14`
     (`oauth-2025-04-20` 없으면 401. interleaved-thinking은 뺐다 — think 토큰 불필요)
   - `anthropic-version: 2023-06-01`
   - `user-agent: claude-cli/2.1.2 (external, cli)`, `x-app: cli`
   - `anthropic-dangerous-direct-browser-access: true`, `accept: application/json`
3. **시스템 프롬프트 = 배열**, **첫 블록이 정확히**
   `"You are Claude Code, Anthropic's official CLI for Claude."` — 평문 문자열로 보내거나
   접두 문자열이 빠지면 거부. 사용자 시스템 프롬프트는 둘째 블록으로.
4. **`max_tokens` 필수** (기본 8192).
5. 도구(tools)는 안 보낸다 — 도구명 PascalCase 강제 규칙은 이 앱과 무관.

## 스트리밍 (Anthropic SSE)

OpenAI와 프레이밍(`data: {json}`)은 같으나 페이로드가 다르다:
- 델타: `type=="content_block_delta"` + `delta.type=="text_delta"` → `delta.text` 방출.
  `thinking_delta`/`input_json_delta`는 무시.
- 종료: `[DONE]` 센티넬이 아니라 `type=="message_stop"` → `.done`.
- 중간 에러: `type=="error"` + `error.message` → `.error` 승격 (삼키면 잘린 출력이
  성공으로 끝남 — 기존 규칙과 동일).
- `event:` 라인은 무시 (data: JSON의 type이 권위).

기존 스트리밍 루프(`\n` 바이트 프레이밍, `sawDone` 없이 끊기면 truncatedStream)를 그대로
재사용. 파서만 3-way 분기: `oauth → native → openai`.

## 토큰 정규화

셋업 토큰은 ~108자. 좁은 터미널 붙여넣기가 토큰 **중간을 줄바꿈으로 쪼갠다** → `trim()`
만으론 부족, **내부 공백까지 전부 제거**. 일반 키는 무변경(기존 동작 보존).
저장(설정) + 읽기(클라이언트) 양쪽에서 `AnthropicOAuth.sanitize` 통과.

## 변경 파일

공통 로직 (양 플랫폼 동일 + 동일 테스트):
- `Sources/LLMCore/AnthropicOAuth.swift` ↔ `windows/AnywhereLLM.Core/AnthropicOAuth.cs`
  — 상수·`isSetupToken`·`sanitize`·`resolveModel`
- `Sources/LLMCore/AnthropicParser.swift` ↔ `windows/AnywhereLLM.Core/AnthropicParser.cs`

클라이언트:
- `Sources/AnywhereLLM/LLMClient.swift` ↔ `windows/AnywhereLLM.App/Services/LlmClient.cs`
  — OAuth 감지, `buildAnthropicRequest`/`applyOAuthHeaders`, 파서 분기, `fetchModels` 분기

설정 UI + 문자열:
- `Sources/AnywhereLLM/SettingsView.swift` ↔ `windows/.../SettingsWindow.xaml(.cs)`
  — 저장 시 sanitize, 감지 시 초록 안내 / 아니면 회색 힌트
- `Resources/*/Localizable.strings` ↔ `Services/Localization.cs` — `settings.apiKeyHint`,
  `settings.setupTokenActive` (en/ko)

테스트:
- `Tests/LLMCoreTests/AnthropicParserTests.swift`, `AnthropicOAuthTests.swift`
- `windows/AnywhereLLM.Core.Tests/Program.cs` (케이스 추가)

## 모델 기본값 (조정 노브)

설정 모델이 Claude가 아니면(기본 `gpt-4o-mini`) `AnthropicOAuth.defaultModel`
(`claude-sonnet-4-5`)로 대체. 설정 필드로 덮어쓰기 가능. 구독 티어별 접근 가능한 최신
모델 id가 다르므로 이 상수 한 곳만 바꾸면 됨. "모델 가져오기"는 OAuth 경로에서
Anthropic `/v1/models`로 자동 전환.

## 검증

- macOS: `swift build` OK, `swift test` 50/50 통과 (AnthropicParser 8 + AnthropicOAuth 7 추가).
- Windows Core: `dotnet run --project windows/AnywhereLLM.Core.Tests` → 58/58 통과.
- WPF 앱(`AnywhereLLM.App`)은 net8.0-windows — macOS에서 컴파일 불가, Windows/CI 필요.

## 수동 테스트 (사용자 실측 필요)

1. `claude setup-token` 실행 → 토큰 복사.
2. 설정 → API Key에 붙여넣기. 초록 "구독 셋업 토큰 인식됨" 안내가 떠야 함.
3. 아무 편집 필드에서 핫키 → 프롬프트 전송 → Claude 응답이 스트리밍돼야 함.
4. "모델 가져오기" → Claude 모델 목록이 떠야 함(구독 접근 범위 내).
5. 잘못된/만료 토큰 → HTTP 401/403 + Anthropic 에러 메시지가 패널에 표시돼야 함.
