using System.Text.Json;
using System.Text.RegularExpressions;

namespace AnywhereLLM.Core;

/// Pure logic for the self-updater: version comparison, GitHub release JSON
/// parsing, asset selection, and checksum-file parsing. No network or file I/O
/// here — that lives in the app's UpdateService. Mirrors Swift LLMCore/UpdateCheck.
public static class UpdateCheck
{
    public sealed record ReleaseAsset(string Name, string DownloadUrl, long Size);
    public sealed record ReleaseInfo(string Tag, IReadOnlyList<ReleaseAsset> Assets);

    /// True only if `latest` is strictly a higher semver than `current`. A leading
    /// "v" is stripped; unparseable input or an equal/older version returns false
    /// (this is the sole downgrade/reinstall guard).
    public static bool IsNewer(string current, string latest)
    {
        var c = Components(current);
        var l = Components(latest);
        if (c is null || l is null) return false;
        int n = Math.Max(c.Length, l.Length);
        for (int i = 0; i < n; i++)
        {
            int cv = i < c.Length ? c[i] : 0;
            int lv = i < l.Length ? l[i] : 0;
            if (lv != cv) return lv > cv;
        }
        return false; // equal
    }

    private static int[]? Components(string version)
    {
        var v = version.Trim();
        if (v.StartsWith("v", StringComparison.OrdinalIgnoreCase)) v = v[1..];
        if (v.Length == 0) return null;
        var parts = v.Split('.');
        var nums = new int[parts.Length];
        for (int i = 0; i < parts.Length; i++)
            if (!int.TryParse(parts[i], out nums[i])) return null;
        return nums;
    }

    /// Parse GitHub's /releases/latest response. Needs tag_name; assets missing
    /// name or browser_download_url are skipped. null on malformed JSON / no tag.
    public static ReleaseInfo? ParseLatestRelease(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (!root.TryGetProperty("tag_name", out var tagEl) || tagEl.ValueKind != JsonValueKind.String)
                return null;

            var assets = new List<ReleaseAsset>();
            if (root.TryGetProperty("assets", out var arr) && arr.ValueKind == JsonValueKind.Array)
            {
                foreach (var a in arr.EnumerateArray())
                {
                    if (a.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String &&
                        a.TryGetProperty("browser_download_url", out var u) && u.ValueKind == JsonValueKind.String)
                    {
                        long size = a.TryGetProperty("size", out var s) && s.ValueKind == JsonValueKind.Number
                            ? s.GetInt64() : 0;
                        assets.Add(new ReleaseAsset(n.GetString()!, u.GetString()!, size));
                    }
                }
            }
            return new ReleaseInfo(tagEl.GetString()!, assets);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// First asset whose name ends with the platform suffix (e.g. "-win-x64.zip"),
    /// so the MSI and the other platform's zip are ignored. null if none match.
    public static ReleaseAsset? PickAsset(IReadOnlyList<ReleaseAsset> assets, string suffix)
    {
        foreach (var a in assets)
            if (a.Name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) return a;
        return null;
    }

    /// Parse a `<sha256>  <filename>` checksum file (sha256sum format; the optional
    /// "*" binary marker is tolerated). Non-conforming lines are ignored. Hashes
    /// are lowercased for case-insensitive comparison. Returns name -> hash.
    public static IReadOnlyDictionary<string, string> ParseChecksums(string text)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var raw in text.Split('\n'))
        {
            var m = Regex.Match(raw.Trim(), "^([0-9a-fA-F]{64})\\s+\\*?(.+)$");
            if (m.Success) map[m.Groups[2].Value.Trim()] = m.Groups[1].Value.ToLowerInvariant();
        }
        return map;
    }
}
