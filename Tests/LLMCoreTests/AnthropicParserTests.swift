import Testing
@testable import LLMCore

@Suite struct AnthropicParserTests {
    @Test func extractsTextDelta() {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
        #expect(AnthropicParser.parse(line: line) == .content("Hello"))
    }

    @Test func messageStopIsDone() {
        #expect(AnthropicParser.parse(line: #"data: {"type":"message_stop"}"#) == .done)
    }

    @Test func eventLinesIgnored() {
        // Anthropic prefixes each data: line with an event: line — the type inside data: is authoritative.
        #expect(AnthropicParser.parse(line: "event: content_block_delta") == .ignore)
        #expect(AnthropicParser.parse(line: "") == .ignore)
        #expect(AnthropicParser.parse(line: ": ping") == .ignore)
    }

    @Test func metaFramesIgnored() {
        #expect(AnthropicParser.parse(line: #"data: {"type":"message_start","message":{"id":"x"}}"#) == .ignore)
        #expect(AnthropicParser.parse(line: #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#) == .ignore)
        #expect(AnthropicParser.parse(line: #"data: {"type":"content_block_stop","index":0}"#) == .ignore)
        #expect(AnthropicParser.parse(line: #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#) == .ignore)
        #expect(AnthropicParser.parse(line: #"data: {"type":"ping"}"#) == .ignore)
    }

    @Test func thinkingDeltaIgnored() {
        // 확장 사고 델타는 화면·타이핑 대상이 아니다 — text_delta만 방출.
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#
        #expect(AnthropicParser.parse(line: line) == .ignore)
    }

    @Test func emptyTextDeltaIgnored() {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}"#
        #expect(AnthropicParser.parse(line: line) == .ignore)
    }

    @Test func midStreamErrorPromoted() {
        let line = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        #expect(AnthropicParser.parse(line: line) == .error("Overloaded"))
    }

    @Test func malformedJSONIgnored() {
        #expect(AnthropicParser.parse(line: "data: {not json") == .ignore)
        #expect(AnthropicParser.parse(line: #"data: {"no":"type"}"#) == .ignore)
    }
}
