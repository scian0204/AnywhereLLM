using System.Windows.Interop;
using AnywhereLLM.Interop;

namespace AnywhereLLM.Services;

/// Global hotkeys via Win32 RegisterHotKey routed through a message-only HwndSource
/// (WM_HOTKEY). Ports the Swift HotkeyManager: holds one or more Hotkey bindings,
/// each with its own id, its own settings-key pair, and its own action; reloads the
/// combos from settings on every Start() so a settings change applies by
/// Stop()/Start(). One WndProc routes WM_HOTKEY by the fired id. Fires even when the
/// app is not foreground; no special permission needed.
///
/// Settings keys (shared names with the mac build, Windows encodings):
///   "hotkeyKeyCode"/"hotkeyModifiers"                — prompt panel (default Ctrl+Shift+Space)
///   "captureHotkeyKeyCode"/"captureHotkeyModifiers"  — screen capture (default Ctrl+Shift+2)
public sealed class HotkeyManager : IDisposable
{
    /// One registered global hotkey: Win32 id, the settings keys holding its combo,
    /// safe defaults, and what to run when it fires.
    public sealed record Hotkey(
        int Id, string KeyCodeKey, string ModifiersKey,
        int DefaultKeyCode, uint DefaultModifiers, Action Action);

    private static readonly IntPtr HwndMessage = new(-3); // HWND_MESSAGE

    // Defaults kept as consts so the settings window can show them without an instance.
    public const int DefaultKeyCode = 0x20; // VK_SPACE
    public const uint DefaultModifiers = NativeMethods.MOD_CONTROL | NativeMethods.MOD_SHIFT;
    public const int DefaultCaptureKeyCode = 0x32; // '2'
    public const uint DefaultCaptureModifiers = NativeMethods.MOD_CONTROL | NativeMethods.MOD_SHIFT;

    private readonly IReadOnlyList<Hotkey> _hotkeys;
    private readonly HashSet<int> _registered = new();
    private HwndSource? _source;

    public HotkeyManager(IReadOnlyList<Hotkey> hotkeys) => _hotkeys = hotkeys;

    public IntPtr Handle => _source?.Handle ?? IntPtr.Zero;

    /// (Re-)register every hotkey from current settings. Returns the ids that FAILED
    /// (empty = all good) so the caller can surface a conflict — a tray-only app whose
    /// only trigger silently dies is unusable.
    public IReadOnlyList<int> Start()
    {
        EnsureSource();
        var failed = new List<int>();
        foreach (var hk in _hotkeys)
        {
            int vk = AppSettings.GetInt(hk.KeyCodeKey, hk.DefaultKeyCode);
            uint mods = (uint)AppSettings.GetInt(hk.ModifiersKey, (int)hk.DefaultModifiers);

            NativeMethods.UnregisterHotKey(_source!.Handle, hk.Id);
            if (NativeMethods.RegisterHotKey(_source.Handle, hk.Id, mods | NativeMethods.MOD_NOREPEAT, (uint)vk))
                _registered.Add(hk.Id);
            else
                failed.Add(hk.Id);
        }
        return failed;
    }

    public void Stop()
    {
        if (_source == null) return;
        foreach (var id in _registered) NativeMethods.UnregisterHotKey(_source.Handle, id);
        _registered.Clear();
    }

    private void EnsureSource()
    {
        if (_source != null) return;
        var p = new HwndSourceParameters("AnywhereLLM.Hotkey")
        {
            ParentWindow = HwndMessage, // message-only window: no UI, still pumps messages
            Width = 0,
            Height = 0,
        };
        _source = new HwndSource(p);
        _source.AddHook(WndProc);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == NativeMethods.WM_HOTKEY)
        {
            int id = wParam.ToInt32();
            var hk = _hotkeys.FirstOrDefault(h => h.Id == id);
            if (hk != null)
            {
                handled = true;
                hk.Action();
            }
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        Stop();
        if (_source != null)
        {
            _source.RemoveHook(WndProc);
            _source.Dispose();
            _source = null;
        }
    }
}
