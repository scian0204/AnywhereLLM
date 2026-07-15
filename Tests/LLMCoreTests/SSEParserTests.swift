import Testing
@testable import LLMCore

@Suite struct SSEParserTests {
    @Test func extractsContentDelta() {
        let line = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        #expect(SSEParser.parse(line: line) == .content("Hello"))
    }

    @Test func doneSentinel() {
        #expect(SSEParser.parse(line: "data: [DONE]") == .done)
    }

    @Test func blankAndNonDataLinesIgnored() {
        #expect(SSEParser.parse(line: "") == .ignore)
        #expect(SSEParser.parse(line: ": keep-alive comment") == .ignore)
        #expect(SSEParser.parse(line: "event: message") == .ignore)
    }

    @Test func roleOnlyDeltaHasNoContent() {
        // First streamed chunk usually carries role but no content.
        let line = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
        #expect(SSEParser.parse(line: line) == .ignore)
    }

    @Test func malformedJSONIgnored() {
        #expect(SSEParser.parse(line: "data: {not json") == .ignore)
    }

    @Test func doneSentinelNoSpace() {
        #expect(SSEParser.parse(line: "data:[DONE]") == .done)
    }

    @Test func usageOnlyFinalChunkIgnored() {
        // stream_options include_usage sends a trailing choices-less usage chunk.
        let line = #"data: {"choices":[],"usage":{"total_tokens":42}}"#
        #expect(SSEParser.parse(line: line) == .ignore)
    }

    @Test func nullContentIgnored() {
        let line = #"data: {"choices":[{"delta":{"content":null}}]}"#
        #expect(SSEParser.parse(line: line) == .ignore)
    }

    @Test func midStreamErrorObject() {
        let line = #"data: {"error":{"message":"rate limited","type":"rate_limit"}}"#
        #expect(SSEParser.parse(line: line) == .error("rate limited"))
    }

    @Test func midStreamErrorString() {
        #expect(SSEParser.parse(line: #"data: {"error":"upstream failure"}"#)
                == .error("upstream failure"))
    }
}
