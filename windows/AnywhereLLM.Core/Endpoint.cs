namespace AnywhereLLM.Core;

/// Base-URL / path joining and origin extraction. The base URL is user-entered
/// (settings), so trailing slashes and whitespace can leak in. Ports the Swift
/// joinEndpoint / endpointOrigin free functions.
public static class Endpoint
{
    /// Join base URL and API path without a double slash.
    public static string Join(string @base, string path)
    {
        var b = @base.Trim();
        while (b.EndsWith("/", StringComparison.Ordinal)) b = b[..^1];
        var p = path.StartsWith("/", StringComparison.Ordinal) ? path : "/" + path;
        return b + p;
    }

    /// scheme://host[:port] origin only (path stripped). null on parse failure.
    /// Ollama's native API (/api/*) attaches to the origin with no /v1 path.
    // ponytail: GetLeftPart(Authority) drops a default port (e.g. :80/:443) that was
    // explicit in the input; the Swift version kept it. No behavior depends on it
    // (used only to reach /api/version and rebuild /api/chat), so this is fine.
    public static string? Origin(string @base)
    {
        if (!Uri.TryCreate(@base.Trim(), UriKind.Absolute, out var url)) return null;
        if (string.IsNullOrEmpty(url.Scheme) || string.IsNullOrEmpty(url.Host)) return null;
        return url.GetLeftPart(UriPartial.Authority);
    }
}
