import Foundation

/// Anthropic Messages API(stream:true) SSE 한 줄 파싱 결과.
/// SSEParser/OllamaChatParser와 같은 모양 — LLMClient가 한 스트리밍 루프에서 소비한다.
public enum AnthropicEvent: Equatable {
    case content(String) // content_block_delta의 text_delta 조각
    case done            // message_stop (Anthropic엔 [DONE] 센티넬이 없다)
    case error(String)   // 스트림 중간 error 이벤트 (overloaded 등)
    case ignore          // event: 라인, ping, message_start/stop 외 메타, thinking_delta 등
}

/// Anthropic SSE 한 줄 파서. OpenAI와 프레이밍은 같으나(data: {json}) 페이로드 모양이 다르다:
/// 종료가 [DONE]이 아니라 type=="message_stop", 델타가 choices가 아니라
/// content_block_delta.delta.text_delta. event: 라인은 무시하고 data: JSON의 type만 본다.
public enum AnthropicParser {
    public static func parse(line: String) -> AnthropicEvent {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return .ignore }

        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty { return .ignore }

        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return .ignore }

        switch type {
        case "message_stop":
            return .done
        case "error":
            // 200 헤더 후 스트림 중간 에러(overloaded_error 등) — 삼키면 잘린 출력이
            // 성공으로 끝나므로 명시적 에러로 승격.
            let err = obj["error"] as? [String: Any]
            return .error(err?["message"] as? String ?? "Anthropic stream error")
        case "content_block_delta":
            // 텍스트 블록의 text_delta만 방출. thinking_delta/input_json_delta는 화면·타이핑 대상 아님.
            guard let delta = obj["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty
            else { return .ignore }
            return .content(text)
        default:
            // message_start, content_block_start/stop, message_delta, ping 등.
            return .ignore
        }
    }
}
