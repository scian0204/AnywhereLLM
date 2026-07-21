using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using AnywhereLLM.Core;

namespace AnywhereLLM.Services;

// Loc = the localization table (renamed from Localization to avoid clashing with
// System.Windows.Localization in files that use `using System.Windows;`).

public sealed record ChatMessage(string Role, string Content);

/// User-facing LLM failure (ports LLMError). Message is already localized.
public sealed class LlmException(string message) : Exception(message);

/// OpenAI-compatible chat completions client over HttpClient. Ports the Swift
/// LLMClient: SSE streaming, Ollama-native /api/chat switch when think is
/// disabled, explicit truncation error, model listing.
public sealed class LlmClient
{
    public const string BaseUrlKey = "llm.baseURL";
    public const string ModelKey = "llm.model";
    public const string DisableThinkKey = "llm.disableThink";

    // Infinite timeout: streaming controls its own lifetime via CancellationToken.
    private static readonly HttpClient Http = new() { Timeout = Timeout.InfiniteTimeSpan };

    public static string BaseUrl
    {
        get
        {
            var v = (AppSettings.GetString(BaseUrlKey) ?? "").Trim();
            return v.Length == 0 ? "https://api.openai.com/v1" : v;
        }
    }

    public static string Model
    {
        get
        {
            var v = (AppSettings.GetString(ModelKey) ?? "").Trim();
            return v.Length == 0 ? "gpt-4o-mini" : v;
        }
    }

    /// Stream assistant content deltas. Throws LlmException on non-200, a
    /// mid-stream error object, or a silently truncated stream.
    public async IAsyncEnumerable<string> StreamChatAsync(
        IReadOnlyList<ChatMessage> messages,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        var disableThink = AppSettings.GetBool(DisableThinkKey, false);
        var baseUrl = BaseUrl;
        var model = Model;
        var apiKey = CredentialStore.Get() is { } k ? AnthropicOAuth.Sanitize(k) : null;
        // A setup token (sk-ant-oat01-) routes to the Anthropic Messages API — ignore
        // the configured Base URL and the Ollama probe.
        bool oauth = AnthropicOAuth.IsSetupToken(apiKey);

        bool native = false;
        if (!oauth && disableThink)
        {
            var origin = Endpoint.Origin(baseUrl);
            if (origin != null) native = await IsOllamaAsync(origin, ct).ConfigureAwait(false);
        }

        using var request = oauth
            ? BuildAnthropicRequest(model, apiKey, messages)
            : BuildChatRequest(baseUrl, model, apiKey, messages, disableThink, native);
        using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct)
            .ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            var msg = await ReadErrorMessageAsync(response, ct).ConfigureAwait(false);
            throw new LlmException(Loc.L("error.httpFailure", (int)response.StatusCode, msg));
        }

        await using var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);

        // Frame on \n ourselves (strip trailing \r). Matches the Swift byte-framing:
        // avoids any reader that would also split on U+2028/2029/0085, which can
        // appear unescaped inside JSON strings and would drop a whole delta line.
        var lineBuf = new List<byte>(4096);
        var readBuf = new byte[8192];
        bool sawDone = false;

        while (true)
        {
            int n = await stream.ReadAsync(readBuf, ct).ConfigureAwait(false);
            if (n == 0) break;
            for (int i = 0; i < n; i++)
            {
                byte b = readBuf[i];
                if (b != 0x0A) { lineBuf.Add(b); continue; }
                foreach (var chunk in HandleLine(lineBuf, oauth, native, ref sawDone)) yield return chunk;
                lineBuf.Clear();
                if (sawDone) yield break;
            }
        }
        if (lineBuf.Count > 0)
            foreach (var chunk in HandleLine(lineBuf, oauth, native, ref sawDone)) yield return chunk;

        // A stream that ends without [DONE]/done:true was cut off (proxy idle
        // timeout etc.) — finishing "successfully" would insert truncated text.
        if (!sawDone) throw new LlmException(Loc.L("error.truncatedStream"));
    }

    private static IEnumerable<string> HandleLine(List<byte> raw, bool oauth, bool native, ref bool sawDone)
    {
        int len = raw.Count;
        if (len > 0 && raw[len - 1] == 0x0D) len--; // CRLF
        var line = Encoding.UTF8.GetString(raw.ToArray(), 0, len);
        var result = oauth ? AnthropicParser.Parse(line)
                   : native ? OllamaChatParser.Parse(line)
                   : SseParser.Parse(line);
        switch (result.Kind)
        {
            case LineKind.Content: return new[] { result.Text };
            case LineKind.Done: sawDone = true; return Array.Empty<string>();
            case LineKind.Error: throw new LlmException(Loc.L("error.httpFailure", 200, result.Text));
            default: return Array.Empty<string>();
        }
    }

    /// GET {baseURL}/models → sorted model ids (for the settings "fetch models" button).
    public async Task<IReadOnlyList<string>> FetchModelsAsync(CancellationToken ct = default)
    {
        var token = CredentialStore.Get() is { } k ? AnthropicOAuth.Sanitize(k) : null;
        bool oauth = AnthropicOAuth.IsSetupToken(token);
        // Setup-token path lists Anthropic /v1/models — same {"data":[{"id":…}]} shape.
        using var request = new HttpRequestMessage(HttpMethod.Get,
            oauth ? AnthropicOAuth.ModelsUrl : Endpoint.Join(BaseUrl, "/models"));
        if (oauth) ApplyOAuthHeaders(request, token);
        else AddAuth(request, token);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(30));
        using var response = await Http.SendAsync(request, cts.Token).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
            throw new LlmException(Loc.L("error.httpFailure", (int)response.StatusCode, body));

        var ids = new List<string>();
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Array)
                foreach (var item in data.EnumerateArray())
                    if (item.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String)
                        ids.Add(id.GetString()!);
        }
        catch (JsonException) { /* leave empty */ }
        ids.Sort(StringComparer.Ordinal);
        return ids;
    }

    private static async Task<bool> IsOllamaAsync(string origin, CancellationToken ct)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(2));
            using var response = await Http.GetAsync(origin + "/api/version", cts.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return false;
            var body = await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
            using var doc = JsonDocument.Parse(body);
            return doc.RootElement.ValueKind == JsonValueKind.Object
                   && doc.RootElement.TryGetProperty("version", out _);
        }
        catch { return false; }
    }

    private static HttpRequestMessage BuildChatRequest(
        string baseUrl, string model, string? apiKey,
        IReadOnlyList<ChatMessage> messages, bool disableThink, bool ollamaNative)
    {
        var b = ollamaNative ? (Endpoint.Origin(baseUrl) ?? baseUrl) : baseUrl;
        var url = Endpoint.Join(b, ollamaNative ? "/api/chat" : "/chat/completions");

        var payload = new Dictionary<string, object>
        {
            ["model"] = model,
            ["stream"] = true,
            ["messages"] = messages.Select(m => new { role = m.Role, content = m.Content }).ToArray(),
        };
        if (ollamaNative)
            payload["think"] = false; // native API only — blocks thinking-token generation
        else if (disableThink)
            payload["chat_template_kwargs"] = new { enable_thinking = false };

        var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json"),
        };
        AddAuth(request, apiKey);
        return request;
    }

    /// Anthropic Messages API request (setup-token path). Unlike OpenAI: system is a
    /// separate top-level array (first block = Claude Code identity, required), messages
    /// carry only user/assistant, and max_tokens is required. System-role messages are
    /// lifted out into the second system block.
    private static HttpRequestMessage BuildAnthropicRequest(
        string model, string? token, IReadOnlyList<ChatMessage> messages)
    {
        var system = new List<object>
        {
            new { type = "text", text = AnthropicOAuth.SystemPrefix, cache_control = new { type = "ephemeral" } },
        };
        var userSystem = string.Join("\n\n",
            messages.Where(m => m.Role == "system").Select(m => m.Content)).Trim();
        if (userSystem.Length > 0)
            system.Add(new { type = "text", text = userSystem, cache_control = new { type = "ephemeral" } });

        var payload = new Dictionary<string, object>
        {
            ["model"] = AnthropicOAuth.ResolveModel(model),
            ["max_tokens"] = AnthropicOAuth.MaxTokens,
            ["stream"] = true,
            ["system"] = system,
            ["messages"] = messages.Where(m => m.Role != "system")
                .Select(m => new { role = m.Role, content = m.Content }).ToArray(),
        };

        var request = new HttpRequestMessage(HttpMethod.Post, AnthropicOAuth.MessagesUrl)
        {
            Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json"),
        };
        ApplyOAuthHeaders(request, token);
        return request;
    }

    /// Headers that make a setup token be recognized as a Claude Code compatible client.
    private static void ApplyOAuthHeaders(HttpRequestMessage request, string? token)
    {
        if (!string.IsNullOrEmpty(token))
            request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + token);
        request.Headers.TryAddWithoutValidation("accept", "application/json");
        request.Headers.TryAddWithoutValidation("anthropic-version", AnthropicOAuth.VersionHeader);
        request.Headers.TryAddWithoutValidation("anthropic-beta", AnthropicOAuth.BetaHeader);
        request.Headers.TryAddWithoutValidation("user-agent", AnthropicOAuth.UserAgent);
        request.Headers.TryAddWithoutValidation("x-app", "cli");
        request.Headers.TryAddWithoutValidation("anthropic-dangerous-direct-browser-access", "true");
    }

    private static void AddAuth(HttpRequestMessage request, string? apiKey)
    {
        if (!string.IsNullOrEmpty(apiKey))
            request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + apiKey);
    }

    /// On a non-200, pull {"error":{"message":…}} or {"error":"…"}, capped at 64KB.
    private static async Task<string> ReadErrorMessageAsync(HttpResponseMessage response, CancellationToken ct)
    {
        string body;
        try
        {
            await using var s = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            var buf = new byte[64_000];
            int total = 0;
            while (total < buf.Length)
            {
                int n = await s.ReadAsync(buf.AsMemory(total, buf.Length - total), ct).ConfigureAwait(false);
                if (n == 0) break;
                total += n;
            }
            body = Encoding.UTF8.GetString(buf, 0, total);
        }
        catch { return Loc.L("error.unknown"); }

        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("error", out var err))
            {
                if (err.ValueKind == JsonValueKind.Object
                    && err.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.String)
                    return m.GetString()!;
                if (err.ValueKind == JsonValueKind.String) return err.GetString()!;
            }
        }
        catch (JsonException) { /* fall through to raw */ }
        return string.IsNullOrWhiteSpace(body) ? Loc.L("error.unknown") : body;
    }
}
