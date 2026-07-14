import Foundation
import LLMCore

struct ChatMessage: Codable {
    let role: String
    let content: String
}

enum LLMError: LocalizedError {
    case invalidBaseURL(String)
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(url):
            return "Base URL이 올바르지 않습니다: \(url)"
        case let .http(status, message):
            return "LLM 요청 실패 (HTTP \(status)): \(message)"
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

    var baseURL: String {
        defaults.string(forKey: Self.baseURLKey) ?? "https://api.openai.com/v1"
    }

    var model: String {
        defaults.string(forKey: Self.modelKey) ?? "gpt-4o-mini"
    }

    /// Streams assistant content deltas. Throws LLMError on non-200; propagates cancellation.
    /// think 끄기가 켜져 있고 서버가 Ollama면 네이티브 /api/chat + think:false로 전환 —
    /// /v1은 think 관련 파라미터를 전부 무시해 생각 토큰이 계속 생성된다 (실측: progress/13).
    func streamChat(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        // Capture config up front so the Task closure captures only Sendable values, not `self`.
        let session = self.session
        let baseURL = self.baseURL
        let model = self.model
        let apiKey = KeychainStore.get()
        let disableThink = defaults.bool(forKey: Self.disableThinkKey)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var native = false
                    if disableThink, let origin = endpointOrigin(baseURL) {
                        native = await Self.isOllama(origin: origin, session: session)
                    }
                    let request = try Self.buildChatRequest(
                        baseURL: baseURL, model: model, apiKey: apiKey,
                        messages: messages, disableThink: disableThink, ollamaNative: native)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.http(status: -1, message: "잘못된 응답")
                    }
                    if http.statusCode != 200 {
                        throw LLMError.http(status: http.statusCode,
                                            message: try await Self.errorMessage(from: bytes))
                    }

                    if native {
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            switch OllamaChatParser.parse(line: line) {
                            case .content(let chunk): continuation.yield(chunk)
                            case .done: continuation.finish(); return
                            case .ignore: continue
                            }
                        }
                    } else {
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            switch SSEParser.parse(line: line) {
                            case .content(let chunk): continuation.yield(chunk)
                            case .done: continuation.finish(); return
                            case .ignore: continue
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
        var request = URLRequest(url: try endpointURL("/models"))
        addAuthIfPresent(&request)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LLMError.http(status: http.statusCode,
                                message: String(data: data, encoding: .utf8) ?? "알 수 없는 오류")
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
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
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
        for try await byte in bytes { data.append(byte) }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = obj["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = obj["error"] as? String {
                return message
            }
        }
        return String(data: data, encoding: .utf8) ?? "알 수 없는 오류"
    }
}
