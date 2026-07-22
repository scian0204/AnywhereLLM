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
    private Forms.ToolStripMenuItem? _updateItem;
    private bool _updateBusy;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ThemeManager.Initialize(); // light/dark following the OS, before any window shows
        SetupTray();

        _hotkey = new HotkeyManager(new[]
        {
            new HotkeyManager.Hotkey(1, "hotkeyKeyCode", "hotkeyModifiers",
                HotkeyManager.DefaultKeyCode, HotkeyManager.DefaultModifiers,
                () => Dispatcher.Invoke(TogglePanel)),
            new HotkeyManager.Hotkey(2, "captureHotkeyKeyCode", "captureHotkeyModifiers",
                HotkeyManager.DefaultCaptureKeyCode, HotkeyManager.DefaultCaptureModifiers,
                () => Dispatcher.Invoke(CaptureRegionAndPrompt)),
        });
        if (_hotkey.Start().Count > 0) WarnHotkeyConflict();

        UpdateService.CleanupOldExe();                  // clear a previous update's "<exe>.old"
        _ = CheckForUpdatesAsync(auto: true);           // silent auto-check on launch
    }

    private void SetupTray()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(Loc.L("menu.settings"), null, (_, _) => Dispatcher.Invoke(OpenSettings));
        _updateItem = new Forms.ToolStripMenuItem(Loc.L("update.check"), null,
            (_, _) => Dispatcher.Invoke(() => _ = CheckForUpdatesAsync(auto: false)));
        menu.Items.Add(_updateItem);
        menu.Items.Add(new Forms.ToolStripMenuItem(Loc.L("menu.build", BuildVersion())) { Enabled = false });
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(Loc.L("menu.quit"), null, (_, _) => Dispatcher.Invoke(Shutdown));

        _tray = new Forms.NotifyIcon
        {
            Icon = LoadAppIcon(),
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

    /// 두 번째 핫키: 화면 영역을 드래그로 캡쳐(Win+Shift+S식)해 이미지 질의 패널을 띄운다.
    /// 보기 전용 컨텍스트라 결과는 패널에 남고 어디에도 삽입되지 않는다.
    private void CaptureRegionAndPrompt()
    {
        // 진행 중이던 세션은 무조건 정리 — immediate 타이핑 중엔 패널이 숨겨져 있어
        // 조건부 dismiss면 스트림이 캡쳐 드래그 동안에도 계속 타이핑된다.
        _panel?.Dismiss();
        var png = RegionCapture.CaptureRegion();
        if (png is null || png.Length == 0) return; // cancelled / failed
        _panel ??= new PromptWindow();
        var ctx = new TargetContext(null, IntPtr.Zero, null, null, false, false, null, png);
        _panel.Present(ctx);
    }

    private void OpenSettings()
        => SettingsWindow.ShowSingleton(ReapplyHotkey);

    private void ReapplyHotkey()
    {
        _hotkey?.Stop();
        if (_hotkey?.Start().Count > 0) WarnHotkeyConflict();
    }

    private void WarnHotkeyConflict()
        => Forms.MessageBox.Show(Loc.L("hotkey.conflictMessage"),
                                 Loc.L("hotkey.conflictTitle"));

    /// Check GitHub for a newer release. auto=true is the silent launch check (no
    /// "up to date" popup, failures swallowed); auto=false is the tray menu action.
    /// On a confirmed+applied update the app shuts down so the helper can swap the exe.
    private async Task CheckForUpdatesAsync(bool auto)
    {
        if (_updateBusy) return;
        _updateBusy = true;
        if (_updateItem != null) { _updateItem.Enabled = false; _updateItem.Text = Loc.L("update.checking"); }
        try
        {
            var rel = await UpdateService.CheckAsync();
            if (rel is null)
            {
                if (!auto) Forms.MessageBox.Show(Loc.L("update.upToDate"), "AnywhereLLM");
                return;
            }

            var choice = Forms.MessageBox.Show(
                Loc.L("update.availableMessage", rel.Tag), Loc.L("update.availableTitle"),
                Forms.MessageBoxButtons.YesNo, Forms.MessageBoxIcon.Information);
            if (choice != Forms.DialogResult.Yes) return;

            if (_updateItem != null) _updateItem.Text = Loc.L("update.downloading");
            var applied = await UpdateService.DownloadAndApplyAsync(rel);
            if (applied) { Shutdown(); return; }   // helper waits for our exit, then swaps + relaunches
            Forms.MessageBox.Show(Loc.L("update.notWritable"), "AnywhereLLM");
        }
        catch (Exception ex)
        {
            Forms.MessageBox.Show(Loc.L("update.failed", ex.Message), "AnywhereLLM",
                Forms.MessageBoxButtons.OK, Forms.MessageBoxIcon.Error);
        }
        finally
        {
            _updateBusy = false;
            if (_updateItem != null) { _updateItem.Enabled = true; _updateItem.Text = Loc.L("update.check"); }
        }
    }

    private static string BuildVersion()
        => Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "?";

    /// The app icon from the exe (multi-res, so the tray can pick the 16px frame).
    private static System.Drawing.Icon LoadAppIcon()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (exe != null && System.Drawing.Icon.ExtractAssociatedIcon(exe) is { } ico) return ico;
        }
        catch { /* fall back below */ }
        return System.Drawing.SystemIcons.Application;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _hotkey?.Dispose();
        if (_tray != null) { _tray.Visible = false; _tray.Dispose(); }
        base.OnExit(e);
    }
}
