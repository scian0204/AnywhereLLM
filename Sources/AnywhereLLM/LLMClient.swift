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
    func streamChat(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        // Build the request and capture the session up front so the Task closure
        // captures only Sendable values (URLRequest, URLSession) — not `self`.
        let session = self.session
        let requestResult = Result { try buildRequest(messages: messages) }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try requestResult.get()
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.http(status: -1, message: "잘못된 응답")
                    }
                    if http.statusCode != 200 {
                        throw LLMError.http(status: http.statusCode,
                                            message: try await Self.errorMessage(from: bytes))
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        switch SSEParser.parse(line: line) {
                        case .content(let chunk): continuation.yield(chunk)
                        case .done: continuation.finish(); return
                        case .ignore: continue
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

    private func buildRequest(messages: [ChatMessage]) throws -> URLRequest {
        var request = URLRequest(url: try endpointURL("/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthIfPresent(&request)

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        // think 모드 끄기 (Qwen3.5 등): vLLM/SGLang/llama.cpp 계열이 인식하는 표준 키.
        // Ollama /v1은 이 키를 무시(미지원) — 그 경우 출력은 ThinkTagFilter가 거른다.
        // OpenAI 등 미인식 서버가 400을 낼 수 있어 옵트인(기본 꺼짐).
        if defaults.bool(forKey: Self.disableThinkKey) {
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

    /// On a non-200, read the body and pull out error.message if present.
    private static func errorMessage(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = obj["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "알 수 없는 오류"
    }
}
