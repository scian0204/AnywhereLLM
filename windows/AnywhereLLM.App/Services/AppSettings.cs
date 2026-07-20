using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AnywhereLLM.Services;

/// String-keyed settings store persisted to %APPDATA%\AnywhereLLM\settings.json.
/// Deliberately mirrors NSUserDefaults semantics (arbitrary keys, typed getters
/// with fallbacks) so the ported ConversationController / settings logic keeps
/// reading the same keys ("applyMode", "systemPrompt", "hotkeyKeyCode", …).
public static class AppSettings
{
    private static readonly object Gate = new();
    private static readonly string Dir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AnywhereLLM");
    private static readonly string FilePath = Path.Combine(Dir, "settings.json");

    private static JsonObject _root = Load();

    private static JsonObject Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonNode.Parse(File.ReadAllText(FilePath)) as JsonObject ?? new JsonObject();
        }
        catch { /* corrupt file → start clean, never crash on launch */ }
        return new JsonObject();
    }

    private static void Save()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            var opts = new JsonSerializerOptions { WriteIndented = true };
            // Atomic write: a torn File.WriteAllText (crash/power-loss/disk-full mid-write)
            // would truncate settings.json, and Load() discards a corrupt file — wiping
            // every stored key. Write a temp file, then rename over the target.
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, _root.ToJsonString(opts));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch { /* best-effort; a failed write must not crash the app */ }
    }

    public static string? GetString(string key)
    {
        lock (Gate) return _root[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
    }

    public static string GetString(string key, string fallback) => GetString(key) ?? fallback;

    public static bool GetBool(string key, bool fallback)
    {
        lock (Gate) return _root[key] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : fallback;
    }

    public static int GetInt(string key, int fallback)
    {
        lock (Gate) return _root[key] is JsonValue v && v.TryGetValue<int>(out var i) ? i : fallback;
    }

    public static void Set(string key, string value) { lock (Gate) { _root[key] = value; Save(); } }
    public static void Set(string key, bool value) { lock (Gate) { _root[key] = value; Save(); } }
    public static void Set(string key, int value) { lock (Gate) { _root[key] = value; Save(); } }

    public static bool Has(string key) { lock (Gate) return _root.ContainsKey(key); }
}
