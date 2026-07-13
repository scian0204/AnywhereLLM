import Foundation

/// Result of parsing one line of an OpenAI-compatible SSE stream.
public enum SSEEvent: Equatable {
    case content(String) // a delta.content chunk to append
    case done            // "[DONE]" sentinel
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

        guard
            let data = payload.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let delta = choices.first?["delta"] as? [String: Any],
            let content = delta["content"] as? String,
            !content.isEmpty
        else {
            return .ignore
        }
        return .content(content)
    }
}
