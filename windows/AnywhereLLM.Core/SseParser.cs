using System.Text.Json;

namespace AnywhereLLM.Core;

/// Pure parser for a single SSE line from /chat/completions with stream:true.
/// Dependency-free and side-effect-free so it can be unit tested directly.
/// Direct port of the Swift SSEParser.
public static class SseParser
{
    public static LineResult Parse(string line)
    {
        var trimmed = line.Trim();
        if (!trimmed.StartsWith("data:", StringComparison.Ordinal)) return LineResult.Ignore;

        var payload = trimmed.Substring("data:".Length).Trim();
        if (payload == "[DONE]") return LineResult.Done;
        if (payload.Length == 0) return LineResult.Ignore;

        JsonElement obj;
        try
        {
            using var doc = JsonDocument.Parse(payload);
            obj = doc.RootElement.Clone();
        }
        catch (JsonException) { return LineResult.Ignore; }
        if (obj.ValueKind != JsonValueKind.Object) return LineResult.Ignore;

        // A 200 header already went out, then the server framed an error mid-stream
        // (vLLM/OpenRouter/llama.cpp/LiteLLM rate-limit, upstream failure, abort).
        // Swallowing it would finish "successfully" with truncated output inserted,
        // so promote it to an explicit error. {"error":{"message":…}} or {"error":"…"}.
        if (obj.TryGetProperty("error", out var err))
        {
            if (err.ValueKind == JsonValueKind.Object
                && err.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.String)
                return LineResult.Error(m.GetString()!);
            if (err.ValueKind == JsonValueKind.String)
                return LineResult.Error(err.GetString()!);
        }

        if (obj.TryGetProperty("choices", out var choices)
            && choices.ValueKind == JsonValueKind.Array && choices.GetArrayLength() > 0)
        {
            var first = choices[0];
            if (first.TryGetProperty("delta", out var delta) && delta.ValueKind == JsonValueKind.Object
                && delta.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.String)
            {
                var s = content.GetString()!;
                if (s.Length > 0) return LineResult.Content(s);
            }
        }
        return LineResult.Ignore;
    }
}
