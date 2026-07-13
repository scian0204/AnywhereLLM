import Testing
@testable import LLMCore

@Suite struct EndpointTests {
    @Test func plainJoin() {
        #expect(joinEndpoint(base: "https://api.openai.com/v1", path: "/models")
                == "https://api.openai.com/v1/models")
    }

    @Test func trailingSlash() {
        #expect(joinEndpoint(base: "http://localhost:11434/v1/", path: "/models")
                == "http://localhost:11434/v1/models")
    }

    @Test func multipleTrailingSlashesAndWhitespace() {
        #expect(joinEndpoint(base: "  http://localhost:1234/v1// ", path: "chat/completions")
                == "http://localhost:1234/v1/chat/completions")
    }

    @Test func pathWithoutLeadingSlash() {
        #expect(joinEndpoint(base: "https://api.openai.com/v1", path: "models")
                == "https://api.openai.com/v1/models")
    }
}
