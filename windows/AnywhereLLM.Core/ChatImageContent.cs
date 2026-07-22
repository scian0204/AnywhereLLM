namespace AnywhereLLM.Core;

/// Builds the JSON-ready `content` value for a chat message that may carry a PNG
/// image. Each provider wants a different shape, so this is the one place that
/// knows all three — pure and dependency-free, unit-tested, and byte-identical to
/// the macOS port (Sources/LLMCore/ChatImageContent.swift).
///
/// Returns `object` so it can be a plain string (no image) or a nested array of
/// anonymous objects (image present); LlmClient hands the result straight to
/// System.Text.Json, which serializes by runtime type.
public static class ChatImageContent
{
    /// OpenAI-compatible chat completions. Plain string when there's no image, else a
    /// content-parts array [{type:text},{type:image_url,image_url:{url:"data:…"}}].
    /// The empty text part is dropped so an image-only turn is valid.
    public static object OpenAI(string text, string? imageBase64)
    {
        if (string.IsNullOrEmpty(imageBase64)) return text;
        var parts = new List<object>();
        if (text.Length > 0) parts.Add(new { type = "text", text });
        parts.Add(new { type = "image_url", image_url = new { url = $"data:image/png;base64,{imageBase64}" } });
        return parts;
    }

    /// Anthropic Messages API. Plain string when there's no image, else content blocks
    /// [{type:text},{type:image,source:{type:base64,media_type:image/png,data:…}}].
    public static object Anthropic(string text, string? imageBase64)
    {
        if (string.IsNullOrEmpty(imageBase64)) return text;
        var blocks = new List<object>();
        if (text.Length > 0) blocks.Add(new { type = "text", text });
        blocks.Add(new { type = "image", source = new { type = "base64", media_type = "image/png", data = imageBase64 } });
        return blocks;
    }

    /// Ollama native /api/chat. Unlike the others, the image rides as a sibling
    /// `images:[base64]` key on the message object (content stays the plain string),
    /// and the base64 must NOT carry a `data:` URI prefix. Returns the images array
    /// to attach, or null when there's no image.
    public static string[]? OllamaImages(string? imageBase64)
        => string.IsNullOrEmpty(imageBase64) ? null : new[] { imageBase64 };
}
