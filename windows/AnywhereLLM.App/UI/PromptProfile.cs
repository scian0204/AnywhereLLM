using System.Text.Json;
using AnywhereLLM.Services;

namespace AnywhereLLM.UI;

/// A named system-prompt profile. Ports the Swift PromptProfile + its storage
/// extension. The active profile's prompt is mirrored into the "systemPrompt" key
/// so ConversationController stays unaware of the profile concept.
public sealed class PromptProfile
{
    public string Name { get; set; } = "";
    public string Prompt { get; set; } = "";

    public const string ProfilesKey = "promptProfiles";
    public const string ActiveKey = "activeProfile";
    public const string MirrorKey = "systemPrompt";

    /// Load stored profiles; if none, treat the legacy single systemPrompt as "Default".
    public static List<PromptProfile> LoadAll()
    {
        var json = AppSettings.GetString(ProfilesKey);
        if (!string.IsNullOrEmpty(json))
        {
            try
            {
                var list = JsonSerializer.Deserialize<List<PromptProfile>>(json);
                if (list is { Count: > 0 }) return list;
            }
            catch (JsonException) { /* fall through to default */ }
        }
        return new List<PromptProfile>
        {
            new() { Name = Loc.L("settings.defaultProfile"), Prompt = AppSettings.GetString(MirrorKey) ?? "" },
        };
    }

    public static void SaveAll(List<PromptProfile> profiles)
        => AppSettings.Set(ProfilesKey, JsonSerializer.Serialize(profiles));

    /// The stored active name if present in the list, else the first profile.
    public static string ActiveName(List<PromptProfile> profiles)
    {
        var stored = AppSettings.GetString(ActiveKey);
        if (!string.IsNullOrEmpty(stored) && profiles.Any(p => p.Name == stored)) return stored;
        return profiles.Count > 0 ? profiles[0].Name : "";
    }

    /// Persist the active name + mirror its prompt into systemPrompt.
    public static void SetActive(string name, List<PromptProfile> profiles)
    {
        AppSettings.Set(ActiveKey, name);
        AppSettings.Set(MirrorKey, profiles.FirstOrDefault(p => p.Name == name)?.Prompt ?? "");
    }
}
