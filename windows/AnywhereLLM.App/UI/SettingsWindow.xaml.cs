using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;
using AnywhereLLM.Core;
using AnywhereLLM.Interop;
using AnywhereLLM.Services;

namespace AnywhereLLM.UI;

/// Settings window (ports SettingsView + SettingsWindowController). Singleton;
/// re-opening brings the existing window forward. All UserDefaults-backed keys
/// map to AppSettings; the API key lives in the Credential Manager.
public partial class SettingsWindow : Window
{
    private const string RunRegKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValueName = "AnywhereLLM";

    private static SettingsWindow? _instance;

    private Action? _onHotkeyChanged;
    private List<PromptProfile> _profiles = new();
    private bool _loading;
    private HotkeyTarget? _recordingTarget;

    private enum HotkeyTarget { Panel, Capture }

    public static void ShowSingleton(Action onHotkeyChanged)
    {
        if (_instance == null)
        {
            _instance = new SettingsWindow();
            _instance.Closed += (_, _) => _instance = null;
        }
        _instance._onHotkeyChanged = onHotkeyChanged;
        _instance.Show();
        _instance.Activate();
    }

    public SettingsWindow()
    {
        InitializeComponent();
        Loaded += (_, _) => Load();
    }

    private void Load()
    {
        _loading = true;
        Title = Loc.L("settings.windowTitle");

        ApiKeyLabel.Text = Loc.L("settings.apiKey");
        ModelLabel.Text = Loc.L("settings.model");
        FetchButton.Content = Loc.L("settings.fetchModels");
        DisableThinkBox.Content = Loc.L("settings.disableThink");
        DisableThinkHelp.Text = Loc.L("settings.disableThinkHelp");
        BehaviorGroup.Header = Loc.L("settings.behavior");
        ApplyModeLabel.Text = Loc.L("settings.applyMode");
        PositionLabel.Text = Loc.L("settings.panelPosition");
        ContextGroup.Header = Loc.L("settings.context");
        IncludeAppNameBox.Content = Loc.L("settings.includeAppName");
        IncludeFullTextBox.Content = Loc.L("settings.includeFullText");
        FullTextWarn.Text = Loc.L("settings.fullTextWarning");
        CleartextWarn.Text = Loc.L("settings.cleartextKeyWarning");
        PromptGroup.Header = Loc.L("settings.systemPrompt");
        AddProfileButton.Content = Loc.L("settings.add");
        RenameProfileButton.Content = Loc.L("settings.rename");
        DeleteProfileButton.Content = Loc.L("settings.delete");
        HotkeyGroup.Header = Loc.L("settings.hotkey");
        HotkeyPanelLabel.Text = Loc.L("settings.hotkeyPanel");
        HotkeyCaptureLabel.Text = Loc.L("settings.hotkeyCapture");
        SystemGroup.Header = Loc.L("settings.system");
        LaunchAtLoginBox.Content = Loc.L("settings.launchAtLogin");

        BaseUrlBox.Text = AppSettings.GetString("llm.baseURL", "https://api.openai.com/v1");
        ModelBox.Text = AppSettings.GetString("llm.model", "gpt-4o-mini");
        ApiKeyBox.Password = CredentialStore.Get() ?? "";
        UpdateApiKeyHint();
        DisableThinkBox.IsChecked = AppSettings.GetBool("llm.disableThink", false);
        DisableThinkHelp.Visibility = DisableThinkBox.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;

        FillCombo(ApplyModeBox, new[] { ("preview", "settings.applyPreview"), ("immediate", "settings.applyImmediate") },
                  AppSettings.GetString("applyMode", "preview"));
        FillCombo(PositionBox, new[] { ("caret", "settings.positionCaret"), ("mouse", "settings.positionMouse"), ("center", "settings.positionCenter") },
                  AppSettings.GetString("panelPosition", "caret"));

        IncludeAppNameBox.IsChecked = AppSettings.GetBool("includeAppName", true);
        IncludeFullTextBox.IsChecked = AppSettings.GetBool("includeFullText", false);
        FullTextWarn.Visibility = IncludeFullTextBox.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;

        LoadProfiles();
        UpdateHotkeyDisplay();
        LaunchAtLoginBox.IsChecked = IsLaunchAtLogin();
        UpdateCleartextWarning();
        _loading = false;
    }

    // MARK: - LLM

    private void BaseUrlBox_TextChanged(object s, TextChangedEventArgs e)
    {
        if (_loading) return;
        AppSettings.Set("llm.baseURL", BaseUrlBox.Text);
        UpdateCleartextWarning();
    }

    private void ModelBox_TextChanged(object s, TextChangedEventArgs e)
    {
        if (_loading) return;
        AppSettings.Set("llm.model", ModelBox.Text);
    }

    private void ApiKeyBox_PasswordChanged(object s, RoutedEventArgs e)
    {
        if (_loading) return;
        // 셋업 토큰이면 내부 공백까지 제거해 저장(터미널 붙여넣기가 줄바꿈을 섞음). 일반 키는 무변경.
        CredentialStore.Set(AnthropicOAuth.Sanitize(ApiKeyBox.Password));
        UpdateApiKeyHint();
        UpdateCleartextWarning();
    }

    /// 셋업 토큰이 감지되면 구독 라우팅 안내(초록), 아니면 키 종류 힌트(회색).
    private void UpdateApiKeyHint()
    {
        bool token = AnthropicOAuth.IsSetupToken(ApiKeyBox.Password);
        ApiKeyHint.Text = Loc.L(token ? "settings.setupTokenActive" : "settings.apiKeyHint");
        ApiKeyHint.Foreground = token
            ? System.Windows.Media.Brushes.SeaGreen
            : System.Windows.Media.Brushes.Gray;
    }

    private void DisableThinkBox_Click(object s, RoutedEventArgs e)
    {
        AppSettings.Set("llm.disableThink", DisableThinkBox.IsChecked == true);
        DisableThinkHelp.Visibility = DisableThinkBox.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void FetchButton_Click(object s, RoutedEventArgs e)
    {
        FetchButton.IsEnabled = false;
        FetchButton.Content = Loc.L("settings.fetching");
        FetchError.Visibility = Visibility.Collapsed;
        try
        {
            var models = await new LlmClient().FetchModelsAsync();
            FetchedModelsBox.ItemsSource = models;
            FetchedModelsBox.Visibility = models.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            if (models.Count == 0) ShowFetchError(Loc.L("settings.emptyModelList"));
        }
        catch (Exception ex) { ShowFetchError(ex.Message); }
        finally
        {
            FetchButton.IsEnabled = true;
            FetchButton.Content = Loc.L("settings.fetchModels");
        }
    }

    private void FetchedModelsBox_SelectionChanged(object s, SelectionChangedEventArgs e)
    {
        if (FetchedModelsBox.SelectedItem is string m) ModelBox.Text = m; // TextBox stays source of truth
    }

    private void ShowFetchError(string msg)
    {
        FetchError.Text = msg;
        FetchError.Visibility = Visibility.Visible;
    }

    // MARK: - Behavior / context

    private void ApplyModeBox_SelectionChanged(object s, SelectionChangedEventArgs e)
    { if (!_loading) AppSettings.Set("applyMode", SelectedTag(ApplyModeBox)); }

    private void PositionBox_SelectionChanged(object s, SelectionChangedEventArgs e)
    { if (!_loading) AppSettings.Set("panelPosition", SelectedTag(PositionBox)); }

    private void IncludeAppNameBox_Click(object s, RoutedEventArgs e)
        => AppSettings.Set("includeAppName", IncludeAppNameBox.IsChecked == true);

    private void IncludeFullTextBox_Click(object s, RoutedEventArgs e)
    {
        AppSettings.Set("includeFullText", IncludeFullTextBox.IsChecked == true);
        FullTextWarn.Visibility = IncludeFullTextBox.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    private void UpdateCleartextWarning()
    {
        bool danger = false;
        var key = ApiKeyBox.Password;
        if (!string.IsNullOrEmpty(key) &&
            Uri.TryCreate(BaseUrlBox.Text.Trim(), UriKind.Absolute, out var url) &&
            string.Equals(url.Scheme, "http", StringComparison.OrdinalIgnoreCase))
        {
            var host = url.Host.ToLowerInvariant();
            danger = host is not ("127.0.0.1" or "localhost" or "::1" or "[::1]");
        }
        CleartextWarn.Visibility = danger ? Visibility.Visible : Visibility.Collapsed;
    }

    // MARK: - Prompt profiles

    private void LoadProfiles()
    {
        _profiles = PromptProfile.LoadAll();
        ProfileBox.ItemsSource = _profiles.Select(p => p.Name).ToList();
        ProfileBox.SelectedItem = PromptProfile.ActiveName(_profiles);
        SyncPromptBox();
        PromptProfile.SaveAll(_profiles);
        PromptProfile.SetActive((string)(ProfileBox.SelectedItem ?? ""), _profiles);
    }

    private void SyncPromptBox()
    {
        var name = ProfileBox.SelectedItem as string;
        PromptBox.Text = _profiles.FirstOrDefault(p => p.Name == name)?.Prompt ?? "";
    }

    private void ProfileBox_SelectionChanged(object s, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (ProfileBox.SelectedItem is string name)
        {
            PromptProfile.SetActive(name, _profiles);
            SyncPromptBox();
        }
    }

    private void PromptBox_TextChanged(object s, TextChangedEventArgs e)
    {
        if (_loading) return;
        var name = ProfileBox.SelectedItem as string;
        var i = _profiles.FindIndex(p => p.Name == name);
        if (i < 0) return;
        _profiles[i].Prompt = PromptBox.Text;
        PromptProfile.SaveAll(_profiles);
        PromptProfile.SetActive(_profiles[i].Name, _profiles);
    }

    private void AddProfile_Click(object s, RoutedEventArgs e)
    {
        var name = UniqueName(Loc.L("settings.newProfile"));
        _profiles.Add(new PromptProfile { Name = name, Prompt = "" });
        RefreshProfiles(name);
    }

    private void RenameProfile_Click(object s, RoutedEventArgs e)
    {
        if (ProfileBox.SelectedItem is not string current) return;
        var input = PromptForName(current);
        if (string.IsNullOrWhiteSpace(input) || input == current) return;
        var i = _profiles.FindIndex(p => p.Name == current);
        if (i < 0) return;
        _profiles[i].Name = UniqueName(input.Trim());
        RefreshProfiles(_profiles[i].Name);
    }

    private void DeleteProfile_Click(object s, RoutedEventArgs e)
    {
        if (_profiles.Count <= 1 || ProfileBox.SelectedItem is not string current) return;
        var i = _profiles.FindIndex(p => p.Name == current);
        if (i < 0) return;
        _profiles.RemoveAt(i);
        RefreshProfiles(_profiles[0].Name);
    }

    private void RefreshProfiles(string select)
    {
        _loading = true;
        ProfileBox.ItemsSource = _profiles.Select(p => p.Name).ToList();
        ProfileBox.SelectedItem = select;
        _loading = false;
        SyncPromptBox();
        PromptProfile.SaveAll(_profiles);
        PromptProfile.SetActive(select, _profiles);
    }

    private string UniqueName(string baseName)
    {
        var name = baseName;
        int n = 2;
        while (_profiles.Any(p => p.Name == name)) name = $"{baseName} {n++}";
        return name;
    }

    // MARK: - Hotkey recording

    private void RecordButton_Click(object s, RoutedEventArgs e) => ToggleRecording(HotkeyTarget.Panel);
    private void RecordCaptureButton_Click(object s, RoutedEventArgs e) => ToggleRecording(HotkeyTarget.Capture);

    private void ToggleRecording(HotkeyTarget target)
    {
        if (_recordingTarget == target) { StopRecording(); return; }
        StopRecording(); // cancel the other row if it was recording
        _recordingTarget = target;
        (target == HotkeyTarget.Panel ? RecordButton : RecordCaptureButton).Content = Loc.L("settings.recordingKeys");
        PreviewKeyDown += RecordKeyDown;
    }

    private void StopRecording()
    {
        _recordingTarget = null;
        PreviewKeyDown -= RecordKeyDown;
        RecordButton.Content = Loc.L("settings.record");
        RecordCaptureButton.Content = Loc.L("settings.record");
    }

    private void RecordKeyDown(object s, KeyEventArgs e)
    {
        if (_recordingTarget is not { } target) return;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftShift or Key.RightShift
                 or Key.LeftAlt or Key.RightAlt or Key.LWin or Key.RWin)
            return; // wait for a non-modifier

        uint mods = 0;
        var m = Keyboard.Modifiers;
        if ((m & ModifierKeys.Control) != 0) mods |= NativeMethods.MOD_CONTROL;
        if ((m & ModifierKeys.Shift) != 0) mods |= NativeMethods.MOD_SHIFT;
        if ((m & ModifierKeys.Alt) != 0) mods |= NativeMethods.MOD_ALT;
        if ((m & ModifierKeys.Windows) != 0) mods |= NativeMethods.MOD_WIN;
        if (mods == 0) { e.Handled = true; return; } // require a modifier

        var (vkKey, modKey) = target == HotkeyTarget.Panel
            ? ("hotkeyKeyCode", "hotkeyModifiers")
            : ("captureHotkeyKeyCode", "captureHotkeyModifiers");
        AppSettings.Set(vkKey, KeyInterop.VirtualKeyFromKey(key));
        AppSettings.Set(modKey, (int)mods);
        e.Handled = true;
        StopRecording();
        UpdateHotkeyDisplay();
        _onHotkeyChanged?.Invoke();
    }

    private void UpdateHotkeyDisplay()
    {
        HotkeyDisplay.Text = FormatHotkey("hotkeyModifiers", "hotkeyKeyCode",
            HotkeyManager.DefaultModifiers, HotkeyManager.DefaultKeyCode);
        CaptureHotkeyDisplay.Text = FormatHotkey("captureHotkeyModifiers", "captureHotkeyKeyCode",
            HotkeyManager.DefaultCaptureModifiers, HotkeyManager.DefaultCaptureKeyCode);
    }

    private static string FormatHotkey(string modsKey, string vkKey, uint defMods, int defVk)
    {
        uint mods = (uint)AppSettings.GetInt(modsKey, (int)defMods);
        int vk = AppSettings.GetInt(vkKey, defVk);
        var sb = new System.Text.StringBuilder();
        if ((mods & NativeMethods.MOD_CONTROL) != 0) sb.Append("Ctrl+");
        if ((mods & NativeMethods.MOD_ALT) != 0) sb.Append("Alt+");
        if ((mods & NativeMethods.MOD_SHIFT) != 0) sb.Append("Shift+");
        if ((mods & NativeMethods.MOD_WIN) != 0) sb.Append("Win+");
        sb.Append(KeyInterop.KeyFromVirtualKey(vk));
        return sb.ToString();
    }

    // MARK: - Launch at login

    private void LaunchAtLoginBox_Click(object s, RoutedEventArgs e)
        => SetLaunchAtLogin(LaunchAtLoginBox.IsChecked == true);

    private static bool IsLaunchAtLogin()
    {
        using var k = Registry.CurrentUser.OpenSubKey(RunRegKey);
        return k?.GetValue(RunValueName) != null;
    }

    private void SetLaunchAtLogin(bool on)
    {
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunRegKey);
            if (on)
            {
                var exe = Environment.ProcessPath ?? System.Diagnostics.Process.GetCurrentProcess().MainModule?.FileName;
                if (exe != null) k?.SetValue(RunValueName, $"\"{exe}\"");
            }
            else { k?.DeleteValue(RunValueName, false); }
        }
        catch { LaunchAtLoginBox.IsChecked = IsLaunchAtLogin(); } // revert to truth
    }

    // MARK: - Helpers

    private static void FillCombo(ComboBox box, (string tag, string key)[] items, string selectedTag)
    {
        box.Items.Clear();
        foreach (var (tag, key) in items)
            box.Items.Add(new ComboBoxItem { Content = Loc.L(key), Tag = tag });
        box.SelectedItem = box.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == selectedTag)
                           ?? box.Items.Cast<ComboBoxItem>().First();
    }

    private static string SelectedTag(ComboBox box)
        => (box.SelectedItem as ComboBoxItem)?.Tag as string ?? "";

    /// Minimal modal name prompt (no external dependency).
    private string? PromptForName(string current)
    {
        var dialog = new Window
        {
            Title = Loc.L("settings.profileName"),
            Width = 300, Height = 130, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = this, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false,
        };
        var tb = new TextBox { Text = current, Margin = new Thickness(12) };
        var ok = new Button { Content = Loc.L("common.ok"), Width = 70, IsDefault = true, Margin = new Thickness(0, 0, 8, 0) };
        var cancel = new Button { Content = Loc.L("common.cancel"), Width = 70, IsCancel = true };
        string? result = null;
        ok.Click += (_, _) => { result = tb.Text; dialog.DialogResult = true; };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(12, 0, 12, 12) };
        buttons.Children.Add(ok);
        buttons.Children.Add(cancel);
        var panel = new DockPanel();
        DockPanel.SetDock(buttons, Dock.Bottom);
        panel.Children.Add(buttons);
        panel.Children.Add(tb);
        dialog.Content = panel;
        return dialog.ShowDialog() == true ? result : null;
    }
}
