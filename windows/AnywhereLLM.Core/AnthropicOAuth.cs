namespace AnywhereLLM.Core;

/// Claude Pro/Max subscription via `claude setup-token` (sk-ant-oat01-…).
/// Pure helpers (constants, detection, sanitize, model resolution) for calling the
/// Anthropic Messages API with a setup token. Direct port of the Swift AnthropicOAuth.
///
/// Setup tokens differ from regular API keys: sent as Bearer, and the request must
/// carry Claude Code identity headers and a system prompt whose first block is exactly
/// the Claude Code identity string, or the API rejects it.
/// Rationale: docs/progress/32-claude-subscription-oauth.md.
public static class AnthropicOAuth
{
    public const string SetupTokenPrefix = "sk-ant-oat01-";

    public const string MessagesUrl = "https://api.anthropic.com/v1/messages";
    public const string ModelsUrl = "https://api.anthropic.com/v1/models";

    /// The first system block must equal this string exactly (typo/omission → rejected).
    public const string SystemPrefix = "You are Claude Code, Anthropic's official CLI for Claude.";

    /// Beta flags that identify a Claude Code compatible client. oauth-2025-04-20 is
    /// required (else 401); interleaved-thinking dropped — no think tokens wanted.
    public const string BetaHeader = "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14";
    public const string VersionHeader = "2023-06-01";
    public const string UserAgent = "claude-cli/2.1.2 (external, cli)";

    /// max_tokens is required by the Messages API.
    public const int MaxTokens = 8192;

    /// Fallback when the configured model isn't a Claude id (e.g. default gpt-4o-mini).
    /// Overridable in settings — one place to change if the tier's model id differs.
    public const string DefaultModel = "claude-sonnet-4-5";

    /// True when the key is a setup token — checked after stripping whitespace,
    /// since a narrow terminal can split the token across lines on paste.
    public static bool IsSetupToken(string? key)
        => key != null && Sanitize(key).StartsWith(SetupTokenPrefix, StringComparison.Ordinal);

    /// Strip ALL whitespace for setup tokens (trim isn't enough — terminals wrap
    /// mid-token). Normal keys are returned unchanged (preserve existing behavior).
    public static string Sanitize(string key)
    {
        var stripped = new string(key.Where(c => !char.IsWhiteSpace(c)).ToArray());
        return stripped.StartsWith(SetupTokenPrefix, StringComparison.Ordinal) ? stripped : key;
    }

    /// Model for the OAuth path: keep the configured value if it looks like a Claude
    /// model, otherwise fall back to the default.
    public static string ResolveModel(string configured)
        => configured.ToLowerInvariant().Contains("claude") ? configured : DefaultModel;
}
