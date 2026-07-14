import Foundation

/// Result of parsing one NDJSON line from Ollama's native /api/chat stream.
public enum OllamaChatEvent: Equatable {
    case content(String) // message.content chunk to append
    case done            // "done": true 종료 라인
    case ignore          // 빈 줄, thinking 전용 청크, 파싱 불가 라인
}

/// Ollama 네이티브 /api/chat (stream:true) NDJSON 한 줄 파서.
/// message.thinking은 의도적으로 버린다 — content만 방출 (생각은 화면/타이핑에 안 나감).
public enum OllamaChatParser {
    public static func parse(line: String) -> OllamaChatEvent {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .ignore }

        // content가 있으면 done 여부와 무관하게 먼저 방출 — 마지막 라인에 내용이
        // 실려 와도 유실되지 않는다 (스트림 종료는 라인 소진으로 처리됨).
        if let msg = obj["message"] as? [String: Any],
           let content = msg["content"] as? String, !content.isEmpty {
            return .content(content)
        }
        return obj["done"] as? Bool == true ? .done : .ignore
    }
}
