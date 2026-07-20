using System.Windows.Interop;
using AnywhereLLM.Interop;

namespace AnywhereLLM.Services;

/// Global hotkey via Win32 RegisterHotKey routed through a message-only HwndSource
/// (WM_HOTKEY). Ports the Swift HotkeyManager: reloads the combo from settings on
/// every Start() so a settings change is applied by Stop()/Start(). Fires even when
/// the app is not foreground; no special permission needed.
///
/// Settings keys (shared names with the mac build, Windows encodings):
///   "hotkeyKeyCode"   — virtual-key code (default VK_SPACE 0x20)
///   "hotkeyModifiers" — MOD_* mask       (default MOD_CONTROL|MOD_SHIFT)
public sealed class HotkeyManager : IDisposable
{
    private const int HotkeyId = 1;
    private static readonly IntPtr HwndMessage = new(-3); // HWND_MESSAGE

    public const int DefaultKeyCode = 0x20; // VK_SPACE
    public const uint DefaultModifiers = NativeMethods.MOD_CONTROL | NativeMethods.MOD_SHIFT;

    private readonly Action _handler;
    private HwndSource? _source;
    private bool _registered;

    public HotkeyManager(Action handler) => _handler = handler;

    public IntPtr Handle => _source?.Handle ?? IntPtr.Zero;

    /// Register (re-register) the hotkey from current settings. Returns false when
    /// another app already owns the combo — the caller surfaces it (a tray-only app
    /// whose only trigger silently dies is unusable).
    public bool Start()
    {
        EnsureSource();
        int vk = AppSettings.GetInt("hotkeyKeyCode", DefaultKeyCode);
        uint mods = (uint)AppSettings.GetInt("hotkeyModifiers", (int)DefaultModifiers);

        NativeMethods.UnregisterHotKey(_source!.Handle, HotkeyId);
        _registered = NativeMethods.RegisterHotKey(
            _source.Handle, HotkeyId, mods | NativeMethods.MOD_NOREPEAT, (uint)vk);
        return _registered;
    }

    public void Stop()
    {
        if (_source != null && _registered)
        {
            NativeMethods.UnregisterHotKey(_source.Handle, HotkeyId);
            _registered = false;
        }
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
        if (msg == NativeMethods.WM_HOTKEY && wParam.ToInt32() == HotkeyId)
        {
            handled = true;
            _handler();
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
