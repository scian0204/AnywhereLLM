import Testing
@testable import LLMCore

@Suite struct AnthropicOAuthTests {
    @Test func detectsSetupToken() {
        #expect(AnthropicOAuth.isSetupToken("sk-ant-oat01-abc123") == true)
        #expect(AnthropicOAuth.isSetupToken("sk-ant-api01-abc123") == false)
        #expect(AnthropicOAuth.isSetupToken("sk-proj-openaikey") == false)
        #expect(AnthropicOAuth.isSetupToken("") == false)
        #expect(AnthropicOAuth.isSetupToken(nil) == false)
    }

    @Test func detectsAcrossWrappedWhitespace() {
        // 좁은 터미널이 붙여넣기 중 토큰을 줄바꿈으로 쪼갠다 — 공백 제거 후에도 인식돼야.
        #expect(AnthropicOAuth.isSetupToken("sk-ant-oat01-aaa\nbbb ccc") == true)
    }

    @Test func sanitizeStripsAllWhitespaceForSetupTokens() {
        #expect(AnthropicOAuth.sanitize("sk-ant-oat01-aaa\n bbb\tccc") == "sk-ant-oat01-aaabbbccc")
    }

    @Test func sanitizeLeavesNormalKeysUntouched() {
        // 일반 키는 공백이 없지만, 있더라도 기존 동작(무변경)을 보존한다.
        #expect(AnthropicOAuth.sanitize("sk-proj-abc") == "sk-proj-abc")
        #expect(AnthropicOAuth.sanitize("with spaces here") == "with spaces here")
    }

    @Test func resolveModelKeepsClaudeIds() {
        #expect(AnthropicOAuth.resolveModel("claude-opus-4-1") == "claude-opus-4-1")
        #expect(AnthropicOAuth.resolveModel("Claude-Sonnet-4-5") == "Claude-Sonnet-4-5")
    }

    @Test func resolveModelReplacesNonClaudeDefaults() {
        // 기본 gpt-4o-mini 등 비-Claude 모델은 OAuth 경로에서 못 쓴다 — 기본 Claude 모델로 대체.
        #expect(AnthropicOAuth.resolveModel("gpt-4o-mini") == AnthropicOAuth.defaultModel)
        #expect(AnthropicOAuth.resolveModel("") == AnthropicOAuth.defaultModel)
    }

    @Test func systemPrefixIsExact() {
        // 첫 시스템 블록이 이 문자열과 정확히 일치하지 않으면 API가 요청을 거부한다.
        #expect(AnthropicOAuth.systemPrefix == "You are Claude Code, Anthropic's official CLI for Claude.")
    }
}
