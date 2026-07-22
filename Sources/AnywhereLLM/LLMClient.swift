import Foundation
import LLMCore

struct ChatMessage: Codable {
    let role: String
    let content: String
    /// Base64 PNG attached to this message (image query). nil for text turns.
    /// `var` with a default so existing call sites stay memberwise-init compatible.
    var imageBase64: String?
}

enum LLMError: LocalizedError {
    case invalidBaseURL(String)
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(url):
            return L("error.invalidBaseURL", url)
        case let .http(status, message):
            return L("error.httpFailure", status, message)
        }
    }
}

/// OpenAI-compatible chat completions client. URLSession only, no dependencies.
final class LLMClient {
    // UserDefaults config keys.
    static let baseURLKey = "llm.baseURL"
    static let modelKey = "llm.model"
    static let disableThinkKey = "llm.disableThink"

    private let defaults: UserDefaults
    private let session: URLSession

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
    }

    // 설정 필드를 지우면 @AppStorage가 nil이 아니라 ""를 저장한다 — ?? 기본값이
    // 발동하지 않아 URL/모델이 빈 문자열로 나가 요청이 불투명한 오류로 실패한다.
    // 공백만 남은 값도 미설정으로 간주해 기본값으로 되돌린다.
    var baseURL: String {
        let v = (defaults.string(forKey: Self.baseURLKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? "https://api.openai.com/v1" : v
    }

    var model: String {
        let v = (defaults.string(forKey: Self.modelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? "gpt-4o-mini" : v
    }

    /// Streams assistant content deltas. Throws LLMError on non-200; propagates cancellation.
    /// think 끄기가 켜져 있고 서버가 Ollama면 네이티브 /api/chat + think:false로 전환 —
    /// /v1은 think 관련 파라미터를 전부 무시해 생각 토큰이 계속 생성된다 (실측: progress/13).
    func streamChat(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        // Capture config up front so the Task closure captures only Sendable values, not `self`.
        let session = self.session
        let baseURL = self.baseURL
        let model = self.model
        let apiKey = KeychainStore.get().map(AnthropicOAuth.sanitize)
        // 셋업 토큰(sk-ant-oat01-)이면 Anthropic Messages API OAuth 경로 — Base URL·Ollama 판별 무시.
        let oauth = AnthropicOAuth.isSetupToken(apiKey)
        let disableThink = defaults.bool(forKey: Self.disableThinkKey)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var native = false
                    if !oauth, disableThink, let origin = endpointOrigin(baseURL) {
                        native = await Self.isOllama(origin: origin, session: session)
                    }
                    let request = oauth
                        ? try Self.buildAnthropicRequest(model: model, token: apiKey, messages: messages)
                        : try Self.buildChatRequest(
                            baseURL: baseURL, model: model, apiKey: apiKey,
                            messages: messages, disableThink: disableThink, ollamaNative: native)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.http(status: -1, message: L("error.invalidResponse"))
                    }
                    if http.statusCode != 200 {
                        throw LLMError.http(status: http.statusCode,
                                            message: try await Self.errorMessage(from: bytes))
                    }

                    // 프로토콜 프레이밍은 \n에만 의존한다. URLSession.AsyncBytes.lines는
                    // U+2028/U+2029/U+0085도 줄바꿈으로 취급하는데, 이 문자들은 JSON 문자열
                    // 안에 이스케이프 없이 올 수 있어(Python 계열 서버가 실제로 그렇게 보냄)
                    // delta 한 줄이 둘로 쪼개져 통째로 유실된다 — 직접 \n 프레이밍으로 회피.
                    let parse = Self.lineParser(oauth: oauth, native: native)
                    var sawDone = false
                    var buf = [UInt8]()

                    func handle(_ bytesLine: [UInt8]) throws {
                        var slice = bytesLine
                        if slice.last == 0x0D { slice.removeLast() } // CRLF
                        switch parse(String(decoding: slice, as: UTF8.self)) {
                        case .content(let chunk): continuation.yield(chunk)
                        case .done: sawDone = true
                        case .error(let msg): throw LLMError.http(status: 200, message: msg)
                        case .ignore: break
                        }
                    }

                    for try await byte in bytes {
                        if byte != 0x0A { buf.append(byte); continue }
                        try Task.checkCancellation()
                        try handle(buf)
                        buf.removeAll(keepingCapacity: true)
                        if sawDone { continuation.finish(); return }
                    }
                    if !buf.isEmpty { try handle(buf) } // 마지막 줄에 \n이 없을 수 있음 (NDJSON)
                    // [DONE]/done:true 없이 연결이 조용히 끊기면(프록시 idle 타임아웃 등)
                    // 잘린 출력이다 — 성공으로 끝내면 immediate 모드가 잘린 텍스트를
                    // 그대로 선택 영역에 덮어쓴다. 명시적 절단 오류로 승격.
                    if sawDone {
                        continuation.finish()
                    } else {
                        throw LLMError.http(status: -1, message: L("error.truncatedStream"))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 한 줄 파싱 결과 — SSE/Ollama 두 파서를 하나의 스트리밍 루프에서 소비하기 위한 공통 표현.
    private enum LineResult { case content(String), done, error(String), ignore }

    /// 경로에 맞는 파서를 골라 공통 LineResult로 사상하는 클로저. oauth > native > openai 우선.
    private static func lineParser(oauth: Bool, native: Bool) -> (String) -> LineResult {
        if oauth {
            return { line in
                switch AnthropicParser.parse(line: line) {
                case .content(let c): return .content(c)
                case .done: return .done
                case .error(let m): return .error(m)
                case .ignore: return .ignore
                }
            }
        }
        if native {
            return { line in
                switch OllamaChatParser.parse(line: line) {
                case .content(let c): return .content(c)
                case .done: return .done
                case .error(let m): return .error(m)
                case .ignore: return .ignore
                }
            }
        }
        return { line in
            switch SSEParser.parse(line: line) {
            case .content(let c): return .content(c)
            case .done: return .done
            case .error(let m): return .error(m)
            case .ignore: return .ignore
            }
        }
    }

    /// origin이 Ollama인지 GET /api/version으로 판별 (2초 타임아웃, 실패 = false).
    /// think 끄기가 켜진 요청에서만 호출되므로 일반 경로엔 비용 없음.
    private static func isOllama(origin: String, session: URLSession) async -> Bool {
        guard let url = URL(string: origin + "/api/version") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return obj["version"] != nil
    }

    /// GET {baseURL}/models → sorted list of model ids. For the settings "모델 가져오기" button.
    /// API 키는 선택 — 로컬 서버(Ollama/LM Studio 등)는 키 없이 동작한다.
    func fetchModels() async throws -> [String] {
        let token = KeychainStore.get().map(AnthropicOAuth.sanitize)
        var request: URLRequest
        if AnthropicOAuth.isSetupToken(token) {
            // 셋업 토큰 경로는 Anthropic /v1/models — 응답 형태는 {"data":[{"id":…}]}로 동일.
            guard let url = URL(string: AnthropicOAuth.modelsURL) else {
                throw LLMError.invalidBaseURL(AnthropicOAuth.modelsURL)
            }
            request = URLRequest(url: url)
            Self.applyOAuthHeaders(&request, token: token)
        } else {
            request = URLRequest(url: try endpointURL("/models"))
            addAuthIfPresent(&request)
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LLMError.http(status: http.statusCode,
                                message: String(data: data, encoding: .utf8) ?? L("error.unknown"))
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = obj?["data"] as? [[String: Any]] ?? []
        return items.compactMap { $0["id"] as? String }.sorted()
    }

    private static func buildChatRequest(baseURL: String, model: String, apiKey: String?,
                                         messages: [ChatMessage], disableThink: Bool,
                                         ollamaNative: Bool) throws -> URLRequest {
        // 네이티브 경로는 /v1 같은 경로를 떼고 origin에 /api/chat을 붙인다.
        let base = ollamaNative ? (endpointOrigin(baseURL) ?? baseURL) : baseURL
        let joined = joinEndpoint(base: base, path: ollamaNative ? "/api/chat" : "/chat/completions")
        guard let url = URL(string: joined) else { throw LLMError.invalidBaseURL(joined) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map { m -> [String: Any] in
                if ollamaNative {
                    // Ollama native: image is a sibling `images:[b64]` key, content stays a string.
                    var dict: [String: Any] = ["role": m.role, "content": m.content]
                    if let images = ChatImageContent.ollamaImages(m.imageBase64) { dict["images"] = images }
                    return dict
                }
                // OpenAI-compatible: content becomes a text+image_url parts array when an image is present.
                return ["role": m.role,
                        "content": ChatImageContent.openAI(text: m.content, imageBase64: m.imageBase64)]
            },
        ]
        if ollamaNative {
            body["think"] = false // 네이티브 API만 인식 — 생각 토큰 생성 자체를 차단
        } else if disableThink {
            // vLLM/SGLang/llama.cpp 계열 표준 키. OpenAI 등 미인식 서버는 400 가능(옵트인).
            body["chat_template_kwargs"] = ["enable_thinking": false]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Anthropic Messages API 요청(셋업 토큰 경로). OpenAI와 다른 점:
    /// system을 별도 최상위 배열로 보내고(첫 블록 = Claude Code 정체성, 필수), messages엔
    /// user/assistant만, max_tokens 필수. 시스템 role 메시지는 뽑아 둘째 블록으로 옮긴다.
    private static func buildAnthropicRequest(model: String, token: String?,
                                              messages: [ChatMessage]) throws -> URLRequest {
        guard let url = URL(string: AnthropicOAuth.messagesURL) else {
            throw LLMError.invalidBaseURL(AnthropicOAuth.messagesURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyOAuthHeaders(&request, token: token)

        // 첫 블록은 반드시 정체성 문자열. 사용자 시스템 프롬프트(들)는 둘째 블록으로 합친다.
        var system: [[String: Any]] = [[
            "type": "text", "text": AnthropicOAuth.systemPrefix,
            "cache_control": ["type": "ephemeral"],
        ]]
        let userSystem = messages.filter { $0.role == "system" }
            .map(\.content).joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !userSystem.isEmpty {
            system.append(["type": "text", "text": userSystem,
                           "cache_control": ["type": "ephemeral"]])
        }

        let convo = messages.filter { $0.role != "system" }
            .map { ["role": $0.role,
                    "content": ChatImageContent.anthropic(text: $0.content, imageBase64: $0.imageBase64)] }
        let body: [String: Any] = [
            "model": AnthropicOAuth.resolveModel(model),
            "max_tokens": AnthropicOAuth.maxTokens,
            "stream": true,
            "system": system,
            "messages": convo,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 셋업 토큰이 Claude Code 호환 클라이언트로 인식되게 하는 헤더 묶음.
    private static func applyOAuthHeaders(_ request: inout URLRequest, token: String?) {
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(AnthropicOAuth.versionHeader, forHTTPHeaderField: "anthropic-version")
        request.setValue(AnthropicOAuth.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(AnthropicOAuth.userAgent, forHTTPHeaderField: "user-agent")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
    }

    /// 설정의 Base URL(끝 슬래시/공백 허용)과 경로를 합쳐 URL을 만든다.
    private func endpointURL(_ path: String) throws -> URL {
        let joined = joinEndpoint(base: baseURL, path: path)
        guard let url = URL(string: joined) else { throw LLMError.invalidBaseURL(joined) }
        return url
    }

    /// 키가 있을 때만 Bearer 헤더 추가 — 키 없는 로컬 서버도 요청 자체는 나간다.
    private func addAuthIfPresent(_ request: inout URLRequest) {
        if let key = KeychainStore.get(), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    /// On a non-200, read the body and pull out the error message if present.
    /// OpenAI 형태({"error":{"message":…}})와 Ollama 형태({"error":"…"}) 모두 지원.
    private static func errorMessage(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        // 서버 응답은 신뢰할 수 없는 입력이다 — 손상/악성 엔드포인트가 끝없는 청크
        // 에러 바디를 흘리면 무한 버퍼링으로 메모리가 고갈된다. 에러 메시지에 64KB면 충분.
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 64_000 { break }
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = obj["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = obj["error"] as? String {
                return message
            }
        }
        return String(data: data, encoding: .utf8) ?? L("error.unknown")
    }
}
