using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace AnywhereLLM.Services;

/// Light/dark theming that follows the Windows app theme (like the macOS build
/// follows system appearance). Two layers:
///  1. WPF Fluent theme (Application.ThemeMode) restyles all standard controls
///     — TextBox, ComboBox, Button, CheckBox, GroupBox, PasswordBox, ScrollBar —
///     and the settings-window chrome for light/dark.
///  2. Custom surface brushes (the prompt panel is a hand-built Border, not a
///     standard control) exposed as DynamicResource keys, swapped to match.
/// Re-applies live when the user flips the OS theme.
public static class ThemeManager
{
    private const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    public static void Initialize()
    {
        Apply();
        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category == UserPreferenceCategory.General)
                Application.Current?.Dispatcher.Invoke(Apply);
        };
    }

    private static void Apply()
    {
        var app = Application.Current;
        if (app == null) return;
        bool dark = IsDark();

#pragma warning disable WPF0001 // ThemeMode is an evaluation (experimental) API
        app.ThemeMode = dark ? ThemeMode.Dark : ThemeMode.Light;
#pragma warning restore WPF0001

        Set(app, "Brush.Surface",       dark ? "#FF202020" : "#FFFBFBFB");
        Set(app, "Brush.SurfaceAlt",    dark ? "#FF2D2D2D" : "#FFF0F0F0");
        Set(app, "Brush.Border",        dark ? "#FF3D3D3D" : "#FFD0D0D0");
        Set(app, "Brush.Text",          dark ? "#FFF0F0F0" : "#FF1A1A1A");
        Set(app, "Brush.TextSecondary", dark ? "#FFB0B0B0" : "#FF666666");
    }

    /// AppsUseLightTheme == 0 means dark. Absent/unreadable ⇒ light.
    private static bool IsDark()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(PersonalizeKey);
            return k?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }

    private static void Set(Application app, string key, string hex)
        => app.Resources[key] = new SolidColorBrush(
            (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex));
}
