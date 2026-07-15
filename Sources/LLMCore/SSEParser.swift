import Foundation

/// Result of parsing one line of an OpenAI-compatible SSE stream.
public enum SSEEvent: Equatable {
    case content(String) // a delta.content chunk to append
    case done            // "[DONE]" sentinel
    case error(String)   // mid-stream error object (server aborted after 200 header)
    case ignore          // blank line, comment, or event without content
}

/// Pure parser for a single SSE line from /chat/completions with stream:true.
/// Kept dependency-free and side-effect-free so it can be unit tested directly.
public enum SSEParser {
    public static func parse(line: String) -> SSEEvent {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return .ignore }

        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        if payload.isEmpty { return .ignore }

        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .ignore }

        // 200 헤더가 이미 나간 뒤 서버가 스트림 중간에 실어 보내는 에러
        // (vLLM/OpenRouter/llama.cpp/LiteLLM의 rate-limit·upstream 실패·중단).
        // {"error":{"message":…}} 또는 {"error":"…"} 형태 — 삼켜서 성공으로 끝나면
        // 잘린 출력이 그대로 삽입되므로 명시적 에러로 승격한다.
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
            return .error(msg)
        }
        if let msg = obj["error"] as? String {
            return .error(msg)
        }

        guard let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty
        else {
            return .ignore
        }
        return .content(content)
    }
}
