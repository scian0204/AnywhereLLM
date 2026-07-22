import Foundation

/// Builds the JSON-ready `content` value for a chat message that may carry a PNG
/// image. Each provider wants a different shape, so this is the one place that
/// knows all three — kept pure and dependency-free so it's unit-testable and stays
/// byte-identical to the Windows port (windows/AnywhereLLM.Core/ChatImageContent.cs).
///
/// The values returned here are fed straight to `JSONSerialization` by LLMClient
/// (which builds untyped `[String: Any]` bodies), so returning `Any` — a plain
/// `String` when there's no image, a nested array/dict when there is — serializes
/// with no extra plumbing.
public enum ChatImageContent {
    /// OpenAI-compatible chat completions. Plain string when there's no image, else a
    /// content-parts array `[{type:text},{type:image_url,image_url:{url:"data:…"}}]`.
    /// The empty text part is dropped so an image-only turn is valid.
    public static func openAI(text: String, imageBase64: String?) -> Any {
        guard let b64 = imageBase64, !b64.isEmpty else { return text }
        var parts: [[String: Any]] = []
        if !text.isEmpty { parts.append(["type": "text", "text": text]) }
        parts.append([
            "type": "image_url",
            "image_url": ["url": "data:image/png;base64,\(b64)"],
        ])
        return parts
    }

    /// Anthropic Messages API. Plain string when there's no image, else content blocks
    /// `[{type:text},{type:image,source:{type:base64,media_type:image/png,data:…}}]`.
    public static func anthropic(text: String, imageBase64: String?) -> Any {
        guard let b64 = imageBase64, !b64.isEmpty else { return text }
        var blocks: [[String: Any]] = []
        if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
        blocks.append([
            "type": "image",
            "source": ["type": "base64", "media_type": "image/png", "data": b64],
        ])
        return blocks
    }

    /// Ollama native /api/chat. Unlike the others, the image rides as a sibling
    /// `images:[base64]` key on the message object (content stays the plain string),
    /// and the base64 must NOT carry a `data:` URI prefix. Returns the images array
    /// to attach, or nil when there's no image.
    public static func ollamaImages(_ imageBase64: String?) -> [String]? {
        guard let b64 = imageBase64, !b64.isEmpty else { return nil }
        return [b64]
    }
}
