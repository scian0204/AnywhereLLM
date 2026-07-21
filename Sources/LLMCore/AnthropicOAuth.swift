import Foundation

/// Claude Pro/Max 구독 연동 — `claude setup-token`이 발급하는 셋업 토큰(sk-ant-oat01-)으로
/// Anthropic Messages API를 호출하기 위한 순수 헬퍼(상수·판별·정규화·모델 해석).
///
/// 셋업 토큰은 일반 API 키(sk-ant-api…)와 다르다: Bearer로 보내고, 요청이 Claude Code
/// 호환 클라이언트에서 온 것으로 식별되도록 특정 헤더 + 시스템 프롬프트 첫 블록이
/// 반드시 Claude Code 정체성 문자열이어야 한다(안 그러면 API가 거부).
/// 배경/근거: docs/progress/32-claude-subscription-oauth.md.
public enum AnthropicOAuth {
    /// 셋업 토큰 접두사. 키가 이걸로 시작하면 OpenAI 호환이 아니라 OAuth 경로로 간다.
    public static let setupTokenPrefix = "sk-ant-oat01-"

    /// Messages API 엔드포인트 — OAuth 경로는 설정의 Base URL을 무시하고 항상 여기로.
    public static let messagesURL = "https://api.anthropic.com/v1/messages"
    /// 모델 목록 — 설정의 "모델 가져오기" 버튼용.
    public static let modelsURL = "https://api.anthropic.com/v1/models"

    /// 시스템 프롬프트 첫 블록에 반드시 정확히 이 문자열이 와야 한다(오탈자·누락 시 거부).
    public static let systemPrefix = "You are Claude Code, Anthropic's official CLI for Claude."

    /// Claude Code 호환 클라이언트로 식별하는 베타 플래그 집합.
    /// oauth-2025-04-20 없으면 401. interleaved-thinking은 뺐다 — think 토큰 불필요.
    public static let betaHeader = "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14"
    public static let versionHeader = "2023-06-01"
    public static let userAgent = "claude-cli/2.1.2 (external, cli)"

    /// max_tokens는 Messages API 필수. 삽입/교체 용도엔 넉넉한 기본값.
    public static let maxTokens = 8192

    /// 설정 모델이 Claude가 아니면(예: 기본 gpt-4o-mini) 이 값으로 대체. 설정에서 덮어쓰기 가능 —
    /// 구독/티어에 따라 접근 가능한 최신 모델 id가 다르므로 여기 한 곳만 바꾸면 된다.
    public static let defaultModel = "claude-sonnet-4-5"

    /// 키가 셋업 토큰인지 — 공백 제거 후 접두사로 판별(터미널 붙여넣기가 줄바꿈을 섞을 수 있음).
    public static func isSetupToken(_ key: String?) -> Bool {
        guard let key else { return false }
        return sanitize(key).hasPrefix(setupTokenPrefix)
    }

    /// 셋업 토큰이면 내부 공백까지 전부 제거(trim만으로는 부족 — 좁은 터미널이 토큰 중간을
    /// 줄바꿈으로 쪼갠다). 일반 키는 그대로 반환(기존 동작 보존).
    public static func sanitize(_ key: String) -> String {
        let stripped = key.components(separatedBy: .whitespacesAndNewlines).joined()
        return stripped.hasPrefix(setupTokenPrefix) ? stripped : key
    }

    /// OAuth 경로에서 쓸 모델. 설정값이 Claude 모델처럼 보이면 존중, 아니면 기본값으로.
    public static func resolveModel(_ configured: String) -> String {
        configured.lowercased().contains("claude") ? configured : defaultModel
    }
}
