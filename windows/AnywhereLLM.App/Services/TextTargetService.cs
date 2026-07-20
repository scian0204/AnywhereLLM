using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Automation;
using AnywhereLLM.Interop;

namespace AnywhereLLM.Services;

/// Snapshot of the focused text target captured at hotkey time.
/// CaretPhysical is in physical screen pixels (for PanelPositioner).
public sealed record TargetContext(
    string? AppName,
    IntPtr TargetHwnd,
    string? SelectedText,
    string? FullText,
    bool IsSecureField,
    bool IsEditable,
    Rect? CaretPhysical);

/// Read/write for the system-wide focused text element. Reads prefer UIA
/// (TextPattern selection, ValuePattern value) with a clipboard-backed Ctrl+C
/// fallback. Writes use SendInput Unicode typing, which replaces the live
/// selection (no clipboard, no paste). Secure (password) fields are hard-blocked.
///
/// This is the Windows analog of the Swift TextTargetService. The macOS build's
/// app-specific AX heuristics (Chrome/VS Code/Slack/KakaoTalk) were empirical;
/// the UIA equivalents here are a first cut — the deny-list philosophy is kept
/// (unknown ⇒ editable, only confidently view-only content is blocked) and app
/// tuning follows via manual testing (see docs/progress/31).
public static class TextTargetService
{
    /// Delay after refocusing the target before typing, so foreground/focus has
    /// actually returned. Shared by apply and streaming-insert (one constant).
    public const int FocusReturnDelayMs = 150;

    // MARK: - Capture

    public static TargetContext Capture()
    {
        IntPtr hwnd = NativeMethods.GetForegroundWindow();
        string? appName = AppNameFor(hwnd);

        AutomationElement? el = TryFocusedElement();
        if (el == null)
        {
            // No UIA focus (native app with no automation). A selection anywhere in
            // the app can only be grabbed via Ctrl+C — a hit = selection we can't
            // locate = view-only. Empty ⇒ editable (Unicode typing needs no UIA).
            var copied = ClipboardCopyFallback(150);
            return string.IsNullOrEmpty(copied)
                ? new TargetContext(appName, hwnd, null, null, false, true, null)
                : new TargetContext(appName, hwnd, copied, null, false, false, null);
        }

        if (IsSecure(el))
            return new TargetContext(appName, hwnd, null, null, true, true, CaretRect(el, hwnd));

        string? selected = ReadSelection(el);
        string? full = ReadValue(el);
        bool editable = IsEditable(el, hasSelection: !string.IsNullOrEmpty(selected));
        return new TargetContext(
            appName, hwnd,
            string.IsNullOrEmpty(selected) ? null : selected,
            string.IsNullOrEmpty(full) ? null : full,
            false, editable, CaretRect(el, hwnd));
    }

    // MARK: - Write

    /// Confirmed insert/replace: refocus the target, wait for focus to return,
    /// then type. Typing replaces a live selection or inserts at the caret.
    /// Run on a background thread (it sleeps).
    public static void ApplyResult(string text, TargetContext ctx)
    {
        if (ctx.IsSecureField) return;
        RefocusTarget(ctx.TargetHwnd);
        Thread.Sleep(FocusReturnDelayMs);
        TypeText(text, ctx.TargetHwnd);
    }

    /// Type text as synthetic Unicode key events — no clipboard, no paste.
    /// expectedHwnd: if the foreground window is no longer this, do nothing (the
    /// user switched apps mid-stream). Re-checks the secure-field hard block.
    public static void TypeText(string text, IntPtr expectedHwnd)
    {
        if (string.IsNullOrEmpty(text)) return;
        if (expectedHwnd != IntPtr.Zero && NativeMethods.GetForegroundWindow() != expectedHwnd) return;

        var focused = TryFocusedElement();
        if (focused != null && IsSecure(focused)) return; // hard block

        // One down+up per UTF-16 code unit; surrogate pairs land as consecutive
        // events and the target recombines them. Batched to keep SendInput calls sane.
        var inputs = new List<NativeMethods.INPUT>(text.Length * 2);
        foreach (char c in text)
        {
            inputs.Add(UnicodeKey(c, up: false));
            inputs.Add(UnicodeKey(c, up: true));
        }
        int size = Marshal.SizeOf<NativeMethods.INPUT>();
        const int batch = 200;
        for (int i = 0; i < inputs.Count; i += batch)
        {
            var slice = inputs.GetRange(i, Math.Min(batch, inputs.Count - i)).ToArray();
            NativeMethods.SendInput((uint)slice.Length, slice, size);
        }
    }

    /// Give foreground back to the captured target window. SetForegroundWindow is
    /// allowed because our (just-dismissed) panel was the foreground process; if it
    /// still fails, attach input queues as a fallback.
    public static void RefocusTarget(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;
        if (NativeMethods.SetForegroundWindow(hwnd)) return;

        uint targetThread = NativeMethods.GetWindowThreadProcessId(hwnd, out _);
        uint current = NativeMethods.GetCurrentThreadId();
        if (targetThread != 0 && NativeMethods.AttachThreadInput(current, targetThread, true))
        {
            try { NativeMethods.SetForegroundWindow(hwnd); }
            finally { NativeMethods.AttachThreadInput(current, targetThread, false); }
        }
    }

    // MARK: - UIA helpers

    private static AutomationElement? TryFocusedElement()
    {
        try { return AutomationElement.FocusedElement; }
        catch { return null; }
    }

    private static bool IsSecure(AutomationElement el)
    {
        try { return (bool)el.GetCurrentPropertyValue(AutomationElement.IsPasswordProperty); }
        catch { return false; }
    }

    private static string? ReadSelection(AutomationElement el)
    {
        try
        {
            if (el.TryGetCurrentPattern(TextPattern.Pattern, out var raw) && raw is TextPattern tp)
            {
                var sel = tp.GetSelection();
                if (sel is { Length: > 0 })
                {
                    var text = sel[0].GetText(100_000);
                    return string.IsNullOrEmpty(text) ? null : text;
                }
            }
        }
        catch { /* UIA can throw on some controls */ }
        return null;
    }

    private static string? ReadValue(AutomationElement el)
    {
        try
        {
            if (el.TryGetCurrentPattern(ValuePattern.Pattern, out var raw) && raw is ValuePattern vp)
            {
                var v = vp.Current.Value;
                if (!string.IsNullOrEmpty(v)) return v;
            }
        }
        catch { }
        try
        {
            if (el.TryGetCurrentPattern(TextPattern.Pattern, out var raw) && raw is TextPattern tp)
            {
                var t = tp.DocumentRange.GetText(100_000);
                if (!string.IsNullOrEmpty(t)) return t;
            }
        }
        catch { }
        return null;
    }

    /// Deny-list: unknown ⇒ editable (typing needs no UIA); only confidently
    /// view-only content returns false. A read-only value that holds a selection is
    /// a read-only text view (Slack message etc.) ⇒ view-only.
    private static bool IsEditable(AutomationElement el, bool hasSelection)
    {
        try
        {
            if (el.TryGetCurrentPattern(ValuePattern.Pattern, out var raw) && raw is ValuePattern vp)
            {
                if (!vp.Current.IsReadOnly) return true;
                if (hasSelection) return false;
            }

            var ct = el.Current.ControlType;
            if (ct == ControlType.Edit || ct == ControlType.ComboBox) return true;
            if (ct == ControlType.Document || ct == ControlType.Text || ct == ControlType.Image
                || ct == ControlType.List || ct == ControlType.Tree || ct == ControlType.Table
                || ct == ControlType.DataGrid || ct == ControlType.Hyperlink)
                return false;
        }
        catch { }
        return true; // unknown / AX error ⇒ editable (matches the mac default direction)
    }

    private static Rect? CaretRect(AutomationElement el, IntPtr hwnd)
    {
        try
        {
            if (el.TryGetCurrentPattern(TextPattern.Pattern, out var raw) && raw is TextPattern tp)
            {
                var sel = tp.GetSelection();
                if (sel is { Length: > 0 })
                {
                    var rects = sel[0].GetBoundingRectangles();
                    if (rects is { Length: > 0 } && rects[0].Height > 0)
                    {
                        var r = rects[0];
                        return new Rect(r.X, r.Y, Math.Max(r.Width, 1), r.Height);
                    }
                }
            }
        }
        catch { }

        // GUITHREADINFO caret (client coords → screen).
        try
        {
            var gti = new NativeMethods.GUITHREADINFO { cbSize = (uint)Marshal.SizeOf<NativeMethods.GUITHREADINFO>() };
            uint tid = NativeMethods.GetWindowThreadProcessId(hwnd, out _);
            if (tid != 0 && NativeMethods.GetGUIThreadInfo(tid, ref gti) && gti.hwndCaret != IntPtr.Zero)
            {
                var pt = new NativeMethods.POINT { X = gti.rcCaret.Left, Y = gti.rcCaret.Top };
                if (NativeMethods.ClientToScreen(gti.hwndCaret, ref pt))
                {
                    int hgt = gti.rcCaret.Bottom - gti.rcCaret.Top;
                    return new Rect(pt.X, pt.Y, 1, hgt > 0 ? hgt : 16);
                }
            }
        }
        catch { }

        // Focused element bounds — only if field-sized (a full-viewport container
        // like a web document is a poor anchor; let the caller fall back to mouse).
        try
        {
            var b = el.Current.BoundingRectangle;
            if (!b.IsEmpty && b.Height > 0 && b.Height <= 300)
                return new Rect(b.X, b.Y, b.Width, b.Height);
        }
        catch { }
        return null;
    }

    private static string? AppNameFor(IntPtr hwnd)
    {
        try
        {
            NativeMethods.GetWindowThreadProcessId(hwnd, out uint pid);
            if (pid != 0)
            {
                using var proc = Process.GetProcessById((int)pid);
                if (!string.IsNullOrEmpty(proc.ProcessName)) return proc.ProcessName;
            }
        }
        catch { }
        // Fallback: window title.
        try
        {
            int len = NativeMethods.GetWindowTextLength(hwnd);
            if (len > 0)
            {
                var sb = new StringBuilder(len + 1);
                NativeMethods.GetWindowText(hwnd, sb, sb.Capacity);
                var t = sb.ToString();
                if (!string.IsNullOrEmpty(t)) return t;
            }
        }
        catch { }
        return null;
    }

    // MARK: - Input synthesis

    private static NativeMethods.INPUT UnicodeKey(char c, bool up) => new()
    {
        type = NativeMethods.INPUT_KEYBOARD,
        U = new NativeMethods.InputUnion
        {
            ki = new NativeMethods.KEYBDINPUT
            {
                wVk = 0,
                wScan = c,
                dwFlags = NativeMethods.KEYEVENTF_UNICODE | (up ? NativeMethods.KEYEVENTF_KEYUP : 0),
            },
        },
    };

    private static NativeMethods.INPUT VKey(ushort vk, bool up) => new()
    {
        type = NativeMethods.INPUT_KEYBOARD,
        U = new NativeMethods.InputUnion
        {
            ki = new NativeMethods.KEYBDINPUT { wVk = vk, dwFlags = up ? NativeMethods.KEYEVENTF_KEYUP : 0 },
        },
    };

    // MARK: - Clipboard fallback (⌘C analog)

    /// Back up the clipboard, send Ctrl+C, poll the clipboard sequence number,
    /// read the copied text, restore the original clipboard. Returns null if
    /// nothing was copied within the timeout. Must run on the STA UI thread
    /// (only called from Capture(), which runs on the hotkey/UI thread).
    private static string? ClipboardCopyFallback(int timeoutMs)
    {
        uint before = NativeMethods.GetClipboardSequenceNumber();
        System.Windows.IDataObject? backup = null;
        try { backup = System.Windows.Clipboard.GetDataObject(); } catch { }

        SendCtrlC();

        string? copied = null;
        var deadline = Environment.TickCount + timeoutMs;
        while (Environment.TickCount < deadline)
        {
            if (NativeMethods.GetClipboardSequenceNumber() != before)
            {
                try { if (System.Windows.Clipboard.ContainsText()) copied = System.Windows.Clipboard.GetText(); }
                catch { }
                break;
            }
            Thread.Sleep(10);
        }

        // Restore only if the clipboard actually changed (avoids a needless bump).
        if (NativeMethods.GetClipboardSequenceNumber() != before && backup != null)
        {
            try { System.Windows.Clipboard.SetDataObject(backup, true); } catch { }
        }
        return copied;
    }

    private static void SendCtrlC()
    {
        var inputs = new[]
        {
            VKey(NativeMethods.VK_CONTROL, up: false),
            VKey(NativeMethods.VK_C, up: false),
            VKey(NativeMethods.VK_C, up: true),
            VKey(NativeMethods.VK_CONTROL, up: true),
        };
        NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.INPUT>());
    }
}
