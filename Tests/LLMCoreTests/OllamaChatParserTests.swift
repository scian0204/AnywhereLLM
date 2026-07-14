import Testing
@testable import LLMCore

@Suite struct OllamaChatParserTests {
    @Test func contentChunk() {
        let line = #"{"message":{"role":"assistant","content":"안녕"},"done":false}"#
        #expect(OllamaChatParser.parse(line: line) == .content("안녕"))
    }

    @Test func thinkingOnlyChunkIgnored() {
        let line = #"{"message":{"role":"assistant","content":"","thinking":"음..."},"done":false}"#
        #expect(OllamaChatParser.parse(line: line) == .ignore)
    }

    @Test func doneLine() {
        let line = #"{"message":{"role":"assistant","content":""},"done":true,"total_duration":123}"#
        #expect(OllamaChatParser.parse(line: line) == .done)
    }

    @Test func contentOnFinalLineNotLost() {
        let line = #"{"message":{"role":"assistant","content":"끝"},"done":true}"#
        #expect(OllamaChatParser.parse(line: line) == .content("끝"))
    }

    @Test func malformedAndEmptyIgnored() {
        #expect(OllamaChatParser.parse(line: "") == .ignore)
        #expect(OllamaChatParser.parse(line: "{not json") == .ignore)
    }
}

@Suite struct EndpointOriginTests {
    @Test func stripsPathKeepsPort() {
        #expect(endpointOrigin("http://192.168.5.182:11434/v1") == "http://192.168.5.182:11434")
    }

    @Test func noPortNoPath() {
        #expect(endpointOrigin("https://api.openai.com/v1") == "https://api.openai.com")
    }

    @Test func trailingSlashAndWhitespace() {
        #expect(endpointOrigin("  http://localhost:11434/v1/ ") == "http://localhost:11434")
    }

    @Test func invalidReturnsNil() {
        #expect(endpointOrigin("설정안함") == nil)
    }
}
