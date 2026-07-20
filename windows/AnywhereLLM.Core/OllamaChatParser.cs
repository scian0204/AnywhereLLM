using System.Text.Json;

namespace AnywhereLLM.Core;

/// Parser for one NDJSON line from Ollama's native /api/chat stream (stream:true).
/// message.thinking is intentionally dropped — only content is emitted.
/// Direct port of the Swift OllamaChatParser.
public static class OllamaChatParser
{
    public static LineResult Parse(string line)
    {
        JsonElement obj;
        try
        {
            using var doc = JsonDocument.Parse(line);
            obj = doc.RootElement.Clone();
        }
        catch (JsonException) { return LineResult.Ignore; }
        if (obj.ValueKind != JsonValueKind.Object) return LineResult.Ignore;

        // On a runner failure a stream that started 200 ends with {"error":"…"} and no done.
        if (obj.TryGetProperty("error", out var err) && err.ValueKind == JsonValueKind.String)
            return LineResult.Error(err.GetString()!);

        // Emit content regardless of done so a final line carrying content isn't lost.
        if (obj.TryGetProperty("message", out var msg) && msg.ValueKind == JsonValueKind.Object
            && msg.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.String)
        {
            var s = content.GetString()!;
            if (s.Length > 0) return LineResult.Content(s);
        }

        return obj.TryGetProperty("done", out var done) && done.ValueKind == JsonValueKind.True
            ? LineResult.Done
            : LineResult.Ignore;
    }
}
