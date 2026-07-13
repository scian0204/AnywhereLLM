# 04 — llm-client

OpenAI 호환 chat completions SSE 스트리밍 클라이언트 + Keychain API 키 저장. 외부 의존성 0 (URLSession + Security 프레임워크만).

## 구현 내용

- **`Sources/LLMCore/SSEParser.swift`** — SSE 한 줄을 파싱하는 순수 함수(라이브러리 타겟). executable 타겟은 테스트에서 import 불가하므로 파서만 별도 `LLMCore` 라이브러리로 분리해 단위 테스트 가능하게 함.
  - `SSEParser.parse(line:) -> SSEEvent`. `SSEEvent = .content(String) | .done | .ignore`.
  - `data:` 프리픽스 검사 → `[DONE]` 종료 → JSON에서 `choices[0].delta.content` 추출. content 없는 delta(예: role만 있는 첫 청크), 주석/빈 줄, 깨진 JSON은 모두 `.ignore`.
- **`Sources/AnywhereLLM/LLMClient.swift`**
  - `struct ChatMessage: Codable { role, content }`.
  - `LLMClient.streamChat(messages:) -> AsyncThrowingStream<String, Error>` — `URLSession.bytes(for:)` + `.lines`로 SSE 파싱, `delta.content`만 yield.
  - HTTP 비 200: 응답 바디에서 `error.message` 추출해 `LLMError.http(status:message:)`로 throw (없으면 raw 바디).
  - 취소: `AsyncThrowingStream.onTermination`에서 내부 `Task.cancel()`, 루프에서 `Task.checkCancellation()`.
  - Swift 6 동시성: `Task` 클로저가 `self`를 캡처하지 않도록 request를 미리 빌드(`Result`)하고 `session`만 캡처.
- **`Sources/AnywhereLLM/KeychainStore.swift`**
  - `kSecClassGenericPassword`, service `kr.scian0204.AnywhereLLM`, account `apiKey`.
  - `get() -> String?`, `set(_:) -> Bool` (update 후 없으면 add), `delete() -> Bool`.
  - static-only `enum` → 상태 없음, Sendable 안전.

## 설정 키

**UserDefaults** (`LLMClient` static 상수):
- `llm.baseURL` — 기본 `"https://api.openai.com/v1"`
- `llm.model` — 기본 `"gpt-4o-mini"`

**Keychain** (`KeychainStore`):
- service `kr.scian0204.AnywhereLLM` / account `apiKey` — API 키

## 스트리밍 인터페이스 사용법

```swift
let client = LLMClient() // UserDefaults.standard, URLSession.shared 기본
let stream = client.streamChat(messages: [
    ChatMessage(role: "system", content: systemPrompt),
    ChatMessage(role: "user", content: userText),
])
do {
    for try await chunk in stream {
        // chunk = delta.content 조각. UI에 append.
    }
} catch let e as LLMError {
    // e.errorDescription = 사용자에게 보여줄 메시지
}
// 취소: stream을 소비하는 Task를 cancel하면 onTermination이 내부 요청을 취소.
```

API 키 설정: `KeychainStore.set("sk-...")`. 미설정 시 스트림 첫 소비에서 `LLMError.missingAPIKey` throw.

## 테스트 결과

`Tests/LLMCoreTests/SSEParserTests.swift` (swift-testing). 5개 케이스 전부 통과:
- content delta 추출 / `[DONE]` 종료 / 빈·주석·비 data 줄 무시 / role-only delta 무시 / 깨진 JSON 무시.

```
swift build   → Build complete (경고 0)
swift test    → 5 tests passed
```

## 다음 단계 인터페이스 (5단계 integration용)

```swift
struct ChatMessage: Codable { let role: String; let content: String }

final class LLMClient {
    static let baseURLKey = "llm.baseURL"   // UserDefaults
    static let modelKey = "llm.model"       // UserDefaults
    init(defaults: UserDefaults = .standard, session: URLSession = .shared)
    var baseURL: String { get }             // 기본 https://api.openai.com/v1
    var model: String { get }               // 기본 gpt-4o-mini
    func streamChat(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
}

enum LLMError: LocalizedError { case missingAPIKey; case http(status: Int, message: String) }

enum KeychainStore {
    static func get() -> String?
    @discardableResult static func set(_ value: String) -> Bool
    @discardableResult static func delete() -> Bool
}
```
