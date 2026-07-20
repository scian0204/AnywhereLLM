using System.Reflection;
using System.Windows;
using AnywhereLLM.Services;
using AnywhereLLM.UI;
using Forms = System.Windows.Forms;

namespace AnywhereLLM;

/// Tray-resident app bootstrap (ports AppDelegate + main.swift). No main window:
/// a NotifyIcon owns the menu; the global hotkey toggles the prompt panel.
/// Windows has no accessibility-permission gate, so that whole flow is dropped.
public partial class App : Application
{
    private Forms.NotifyIcon? _tray;
    private HotkeyManager? _hotkey;
    private PromptWindow? _panel;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ThemeManager.Initialize(); // light/dark following the OS, before any window shows
        SetupTray();

        _hotkey = new HotkeyManager(() => Dispatcher.Invoke(TogglePanel));
        if (!_hotkey.Start()) WarnHotkeyConflict();
    }

    private void SetupTray()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(Loc.L("menu.settings"), null, (_, _) => Dispatcher.Invoke(OpenSettings));
        menu.Items.Add(new Forms.ToolStripMenuItem(Loc.L("menu.build", BuildVersion())) { Enabled = false });
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(Loc.L("menu.quit"), null, (_, _) => Dispatcher.Invoke(Shutdown));

        _tray = new Forms.NotifyIcon
        {
            Icon = System.Drawing.SystemIcons.Application,
            Visible = true,
            Text = "AnywhereLLM",
            ContextMenuStrip = menu,
        };
        _tray.MouseClick += (_, ev) =>
        {
            if (ev.Button == Forms.MouseButtons.Left) Dispatcher.Invoke(TogglePanel);
        };
    }

    /// Capture the target BEFORE showing the panel — focus changes once it appears.
    private void TogglePanel()
    {
        _panel ??= new PromptWindow();
        if (_panel.IsVisible) { _panel.Dismiss(); return; }

        var ctx = TextTargetService.Capture();
        if (ctx.IsSecureField) { System.Media.SystemSounds.Beep.Play(); return; } // hard rule
        _panel.Present(ctx);
    }

    private void OpenSettings()
        => SettingsWindow.ShowSingleton(ReapplyHotkey);

    private void ReapplyHotkey()
    {
        _hotkey?.Stop();
        if (_hotkey?.Start() == false) WarnHotkeyConflict();
    }

    private void WarnHotkeyConflict()
        => Forms.MessageBox.Show(Loc.L("hotkey.conflictMessage"),
                                 Loc.L("hotkey.conflictTitle"));

    private static string BuildVersion()
        => Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "?";

    protected override void OnExit(ExitEventArgs e)
    {
        _hotkey?.Dispose();
        if (_tray != null) { _tray.Visible = false; _tray.Dispose(); }
        base.OnExit(e);
    }
}
