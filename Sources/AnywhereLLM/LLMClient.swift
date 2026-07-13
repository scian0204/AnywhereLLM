import Foundation
import LLMCore

struct ChatMessage: Codable {
    let role: String
    let content: String
}

enum LLMError: LocalizedError {
    case missingAPIKey
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API 키가 설정되지 않았습니다. 설정에서 키를 입력하세요."
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

    private func buildRequest(messages: [ChatMessage]) throws -> URLRequest {
        guard let key = KeychainStore.get(), !key.isEmpty else {
            throw LLMError.missingAPIKey
        }
        var request = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
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
