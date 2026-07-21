using System.Text.Json;

namespace AnywhereLLM.Core;

/// Parser for a single SSE line from the Anthropic Messages API (stream:true).
/// Same framing as OpenAI (data: {json}) but a different payload shape: the stream
/// ends on type=="message_stop" (no [DONE] sentinel), and deltas arrive as
/// content_block_delta.delta.text_delta rather than choices[].delta.content.
/// event: lines are ignored — the type inside the data: JSON is authoritative.
/// Direct port of the Swift AnthropicParser; returns the shared LineResult.
public static class AnthropicParser
{
    public static LineResult Parse(string line)
    {
        var trimmed = line.Trim();
        if (!trimmed.StartsWith("data:", StringComparison.Ordinal)) return LineResult.Ignore;

        var payload = trimmed.Substring("data:".Length).Trim();
        if (payload.Length == 0) return LineResult.Ignore;

        JsonElement obj;
        try
        {
            using var doc = JsonDocument.Parse(payload);
            obj = doc.RootElement.Clone();
        }
        catch (JsonException) { return LineResult.Ignore; }
        if (obj.ValueKind != JsonValueKind.Object) return LineResult.Ignore;
        if (!obj.TryGetProperty("type", out var typeEl) || typeEl.ValueKind != JsonValueKind.String)
            return LineResult.Ignore;

        switch (typeEl.GetString())
        {
            case "message_stop":
                return LineResult.Done;
            case "error":
                // Mid-stream error after the 200 header (overloaded_error etc.) —
                // swallowing it would finish "successfully" with truncated output.
                if (obj.TryGetProperty("error", out var err) && err.ValueKind == JsonValueKind.Object
                    && err.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.String)
                    return LineResult.Error(m.GetString()!);
                return LineResult.Error("Anthropic stream error");
            case "content_block_delta":
                // Only text_delta on a text block. thinking_delta/input_json_delta aren't shown/typed.
                if (obj.TryGetProperty("delta", out var delta) && delta.ValueKind == JsonValueKind.Object
                    && delta.TryGetProperty("type", out var dt) && dt.ValueKind == JsonValueKind.String
                    && dt.GetString() == "text_delta"
                    && delta.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String)
                {
                    var s = text.GetString()!;
                    if (s.Length > 0) return LineResult.Content(s);
                }
                return LineResult.Ignore;
            default:
                // message_start, content_block_start/stop, message_delta, ping, etc.
                return LineResult.Ignore;
        }
    }
}
