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
}
