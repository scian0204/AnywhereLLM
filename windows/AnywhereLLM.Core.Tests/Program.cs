using AnywhereLLM.Core;

// Dependency-free test runner (no NuGet, offline-safe) porting the four Swift
// LLMCore test suites: SSEParser, ThinkTagFilter, Endpoint, OllamaChatParser.
// Exit code 0 = all pass, 1 = any failure — the CI/`make test` signal.

var t = new Runner();

// ---- SseParser ---------------------------------------------------------------
t.Eq("SSE.extractsContentDelta",
    SseParser.Parse("""data: {"choices":[{"delta":{"content":"Hello"}}]}"""),
    LineResult.Content("Hello"));
t.Eq("SSE.doneSentinel", SseParser.Parse("data: [DONE]"), LineResult.Done);
t.Eq("SSE.blank", SseParser.Parse(""), LineResult.Ignore);
t.Eq("SSE.comment", SseParser.Parse(": keep-alive comment"), LineResult.Ignore);
t.Eq("SSE.eventLine", SseParser.Parse("event: message"), LineResult.Ignore);
t.Eq("SSE.roleOnlyDelta",
    SseParser.Parse("""data: {"choices":[{"delta":{"role":"assistant"}}]}"""),
    LineResult.Ignore);
t.Eq("SSE.malformedJSON", SseParser.Parse("data: {not json"), LineResult.Ignore);
t.Eq("SSE.doneNoSpace", SseParser.Parse("data:[DONE]"), LineResult.Done);
t.Eq("SSE.usageOnlyChunk",
    SseParser.Parse("""data: {"choices":[],"usage":{"total_tokens":42}}"""),
    LineResult.Ignore);
t.Eq("SSE.nullContent",
    SseParser.Parse("""data: {"choices":[{"delta":{"content":null}}]}"""),
    LineResult.Ignore);
t.Eq("SSE.midStreamErrorObject",
    SseParser.Parse("""data: {"error":{"message":"rate limited","type":"rate_limit"}}"""),
    LineResult.Error("rate limited"));
t.Eq("SSE.midStreamErrorString",
    SseParser.Parse("""data: {"error":"upstream failure"}"""),
    LineResult.Error("upstream failure"));

// ---- ThinkTagFilter ----------------------------------------------------------
static string Run(params string[] chunks)
{
    var f = new ThinkTagFilter();
    var sb = new System.Text.StringBuilder();
    foreach (var c in chunks) sb.Append(f.Feed(c));
    sb.Append(f.Flush());
    return sb.ToString();
}
t.Eq("Think.noThink", Run("Hello, ", "world!"), "Hello, world!");
t.Eq("Think.completeBlock", Run("<think>reasoning here</think>answer"), "answer");
t.Eq("Think.splitAcrossChunks",
    Run("before <th", "ink>hidden", " stuff</thi", "nk>after"), "before after");
t.Eq("Think.openNeverClosed", Run("visible <think>never closed reasoning"), "visible ");
t.Eq("Think.partialNotATag", Run("a<th", "en b"), "a<then b");
t.Eq("Think.multipleBlocks", Run("<think>x</think>A<think>y</think>B"), "AB");
t.Eq("Think.lessThanAlone", Run("1 < 2 and ", "3 > 2"), "1 < 2 and 3 > 2");
t.Eq("Think.endsOnHeldPartial", Run("abc<thi"), "abc<thi");
t.Eq("Think.strayCloseTag", Run("a</think>b"), "a</think>b");

// ---- Endpoint.Join -----------------------------------------------------------
t.Eq("Join.plain", Endpoint.Join("https://api.openai.com/v1", "/models"),
    "https://api.openai.com/v1/models");
t.Eq("Join.trailingSlash", Endpoint.Join("http://localhost:11434/v1/", "/models"),
    "http://localhost:11434/v1/models");
t.Eq("Join.multiSlashAndWhitespace",
    Endpoint.Join("  http://localhost:1234/v1// ", "chat/completions"),
    "http://localhost:1234/v1/chat/completions");
t.Eq("Join.noLeadingSlash", Endpoint.Join("https://api.openai.com/v1", "models"),
    "https://api.openai.com/v1/models");

// ---- Endpoint.Origin ---------------------------------------------------------
t.Eq("Origin.stripsPathKeepsPort", Endpoint.Origin("http://192.168.5.182:11434/v1"),
    "http://192.168.5.182:11434");
t.Eq("Origin.noPortNoPath", Endpoint.Origin("https://api.openai.com/v1"),
    "https://api.openai.com");
t.Eq("Origin.trailingSlashWhitespace", Endpoint.Origin("  http://localhost:11434/v1/ "),
    "http://localhost:11434");
t.Eq("Origin.invalidReturnsNull", Endpoint.Origin("설정안함"), null);
t.Eq("Origin.ipv6KeepsBrackets", Endpoint.Origin("http://[::1]:11434/v1"),
    "http://[::1]:11434");

// ---- OllamaChatParser --------------------------------------------------------
t.Eq("Ollama.contentChunk",
    OllamaChatParser.Parse("""{"message":{"role":"assistant","content":"안녕"},"done":false}"""),
    LineResult.Content("안녕"));
t.Eq("Ollama.thinkingOnlyIgnored",
    OllamaChatParser.Parse("""{"message":{"role":"assistant","content":"","thinking":"음..."},"done":false}"""),
    LineResult.Ignore);
t.Eq("Ollama.doneLine",
    OllamaChatParser.Parse("""{"message":{"role":"assistant","content":""},"done":true,"total_duration":123}"""),
    LineResult.Done);
t.Eq("Ollama.contentOnFinalLine",
    OllamaChatParser.Parse("""{"message":{"role":"assistant","content":"끝"},"done":true}"""),
    LineResult.Content("끝"));
t.Eq("Ollama.empty", OllamaChatParser.Parse(""), LineResult.Ignore);
t.Eq("Ollama.malformed", OllamaChatParser.Parse("{not json"), LineResult.Ignore);
t.Eq("Ollama.midStreamError",
    OllamaChatParser.Parse("""{"error":"model runner has unexpectedly stopped"}"""),
    LineResult.Error("model runner has unexpectedly stopped"));
t.Eq("Ollama.messageNoContent",
    OllamaChatParser.Parse("""{"message":{"role":"assistant"},"done":false}"""),
    LineResult.Ignore);

// ---- AnthropicParser ---------------------------------------------------------
t.Eq("Anthropic.textDelta",
    AnthropicParser.Parse("""data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"""),
    LineResult.Content("Hello"));
t.Eq("Anthropic.messageStopDone",
    AnthropicParser.Parse("""data: {"type":"message_stop"}"""), LineResult.Done);
t.Eq("Anthropic.eventLineIgnored", AnthropicParser.Parse("event: content_block_delta"), LineResult.Ignore);
t.Eq("Anthropic.blank", AnthropicParser.Parse(""), LineResult.Ignore);
t.Eq("Anthropic.messageStartIgnored",
    AnthropicParser.Parse("""data: {"type":"message_start","message":{"id":"x"}}"""), LineResult.Ignore);
t.Eq("Anthropic.pingIgnored", AnthropicParser.Parse("""data: {"type":"ping"}"""), LineResult.Ignore);
t.Eq("Anthropic.thinkingDeltaIgnored",
    AnthropicParser.Parse("""data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"""),
    LineResult.Ignore);
t.Eq("Anthropic.emptyTextDeltaIgnored",
    AnthropicParser.Parse("""data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}"""),
    LineResult.Ignore);
t.Eq("Anthropic.midStreamError",
    AnthropicParser.Parse("""data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"""),
    LineResult.Error("Overloaded"));
t.Eq("Anthropic.malformedJSON", AnthropicParser.Parse("data: {not json"), LineResult.Ignore);
t.Eq("Anthropic.noType", AnthropicParser.Parse("""data: {"no":"type"}"""), LineResult.Ignore);

// ---- AnthropicOAuth ----------------------------------------------------------
t.Eq("OAuth.detectsSetupToken", AnthropicOAuth.IsSetupToken("sk-ant-oat01-abc123"), true);
t.Eq("OAuth.rejectsApiKey", AnthropicOAuth.IsSetupToken("sk-ant-api01-abc123"), false);
t.Eq("OAuth.rejectsNull", AnthropicOAuth.IsSetupToken(null), false);
t.Eq("OAuth.detectsWrappedWhitespace", AnthropicOAuth.IsSetupToken("sk-ant-oat01-aaa\nbbb ccc"), true);
t.Eq("OAuth.sanitizeStripsWhitespace",
    AnthropicOAuth.Sanitize("sk-ant-oat01-aaa\n bbb\tccc"), "sk-ant-oat01-aaabbbccc");
t.Eq("OAuth.sanitizeLeavesNormalKey", AnthropicOAuth.Sanitize("with spaces"), "with spaces");
t.Eq("OAuth.resolveKeepsClaude", AnthropicOAuth.ResolveModel("claude-opus-4-1"), "claude-opus-4-1");
t.Eq("OAuth.resolveReplacesNonClaude", AnthropicOAuth.ResolveModel("gpt-4o-mini"), AnthropicOAuth.DefaultModel);
t.Eq("OAuth.systemPrefixExact",
    AnthropicOAuth.SystemPrefix, "You are Claude Code, Anthropic's official CLI for Claude.");

// ---- UpdateCheck -------------------------------------------------------------
t.Eq("Update.newerMinor", UpdateCheck.IsNewer("0.4.1", "0.5.0"), true);
t.Eq("Update.newerDoubleDigit", UpdateCheck.IsNewer("0.4.1", "0.4.10"), true);
t.Eq("Update.equalNotNewer", UpdateCheck.IsNewer("0.5.0", "0.5.0"), false);
t.Eq("Update.olderNotNewer", UpdateCheck.IsNewer("0.5.0", "0.4.9"), false);
t.Eq("Update.vPrefixStripped", UpdateCheck.IsNewer("0.4.1", "v0.5.0"), true);
t.Eq("Update.garbageNotNewer", UpdateCheck.IsNewer("0.4.1", "garbage"), false);
t.Eq("Update.shorterCurrent", UpdateCheck.IsNewer("0.4", "0.4.1"), true);

const string relJson = """
{"tag_name":"v0.5.0","assets":[
{"name":"AnywhereLLM-0.5.0-win-x64.zip","browser_download_url":"https://x/win.zip","size":123},
{"name":"AnywhereLLM-0.5.0-x64.msi","browser_download_url":"https://x/app.msi","size":456},
{"name":"SHA256SUMS.txt","browser_download_url":"https://x/sums","size":10}]}
""";
var rel = UpdateCheck.ParseLatestRelease(relJson);
t.Eq("Update.parseTag", rel?.Tag, "v0.5.0");
t.Eq("Update.parseAssetCount", rel?.Assets.Count, 3);
t.Eq("Update.pickWinZip",
    UpdateCheck.PickAsset(rel!.Assets, "-win-x64.zip")?.Name, "AnywhereLLM-0.5.0-win-x64.zip");
t.Eq("Update.pickWinUrl",
    UpdateCheck.PickAsset(rel!.Assets, "-win-x64.zip")?.DownloadUrl, "https://x/win.zip");
t.Eq("Update.pickMacNoneOnWin", UpdateCheck.PickAsset(rel!.Assets, "-macos.zip"), null);
t.Eq("Update.parseMalformed", UpdateCheck.ParseLatestRelease("{not json"), null);
t.Eq("Update.parseNoTag", UpdateCheck.ParseLatestRelease("{}"), null);

var sums = UpdateCheck.ParseChecksums(
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  AnywhereLLM-0.5.0-win-x64.zip\n" +
    "# a comment line\n" +
    "0000000000000000000000000000000000000000000000000000000000000000 *AnywhereLLM-0.5.0-x64.msi\n");
t.Eq("Update.checksumWinZip",
    sums.TryGetValue("AnywhereLLM-0.5.0-win-x64.zip", out var h1) ? h1 : null,
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
t.Eq("Update.checksumBinaryMarker",
    sums.TryGetValue("AnywhereLLM-0.5.0-x64.msi", out var h2) ? h2 : null,
    "0000000000000000000000000000000000000000000000000000000000000000");
t.Eq("Update.checksumCount", sums.Count, 2);

return t.Report();

sealed class Runner
{
    private int _pass, _fail;

    public void Eq<T>(string name, T actual, T expected)
    {
        if (Equals(actual, expected)) { _pass++; return; }
        _fail++;
        Console.WriteLine($"FAIL {name}\n  expected: {Fmt(expected)}\n  actual:   {Fmt(actual)}");
    }

    private static string Fmt(object? o) => o switch
    {
        null => "null",
        string s => $"\"{s}\"",
        _ => o.ToString() ?? "null",
    };

    public int Report()
    {
        Console.WriteLine($"\n{_pass} passed, {_fail} failed");
        return _fail == 0 ? 0 : 1;
    }
}
