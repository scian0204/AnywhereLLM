using System.Windows;
using System.Windows.Media;
using AnywhereLLM.Interop;
using Forms = System.Windows.Forms;

namespace AnywhereLLM.Services;

/// Places the prompt panel. Setting "panelPosition":
///   "caret" (default) — the captured caret/selection rect, falling back to cursor
///   "mouse"           — at the mouse pointer
///   "center"          — centered on the monitor under the mouse
///
/// Caret geometry is captured in physical pixels (UIA/GUITHREADINFO). This converts
/// to WPF DIPs using the panel window's current DPI, then clamps to the work area.
public static class PanelPositioner
{
    /// Call after the window is shown (so its DPI and ActualWidth/Height are known).
    public static void Position(Window window, TargetContext ctx)
    {
        var dpi = VisualTreeHelper.GetDpi(window);
        double sx = dpi.DpiScaleX <= 0 ? 1 : dpi.DpiScaleX;
        double sy = dpi.DpiScaleY <= 0 ? 1 : dpi.DpiScaleY;

        double w = window.ActualWidth > 0 ? window.ActualWidth : window.Width;
        double h = window.ActualHeight > 0 ? window.ActualHeight : window.Height;

        var mode = AppSettings.GetString("panelPosition", "caret");
        NativeMethods.GetCursorPos(out var cursor); // physical px

        double left, top;
        if (mode == "center")
        {
            var scr = Forms.Screen.FromPoint(new System.Drawing.Point(cursor.X, cursor.Y)).Bounds;
            left = (scr.X + scr.Width / 2.0) / sx - w / 2.0;
            top = (scr.Y + scr.Height / 2.0) / sy - h / 2.0;
        }
        else
        {
            // Anchor rect in physical px: caret (if captured) else the mouse point.
            Rect anchor = mode == "mouse" || ctx.CaretPhysical is null
                ? new Rect(cursor.X, cursor.Y, 0, 0)
                : ctx.CaretPhysical.Value;

            // Just below the anchor's bottom-left, converted to DIP.
            left = anchor.X / sx;
            top = (anchor.Y + anchor.Height) / sy + 4;
        }

        Clamp(ref left, ref top, w, h, cursor, sx, sy);
        window.Left = left;
        window.Top = top;
    }

    private static void Clamp(ref double left, ref double top, double w, double h,
                              NativeMethods.POINT cursor, double sx, double sy)
    {
        var wa = Forms.Screen.FromPoint(new System.Drawing.Point(cursor.X, cursor.Y)).WorkingArea;
        double minX = wa.X / sx, minY = wa.Y / sy;
        double maxX = (wa.X + wa.Width) / sx - w;
        double maxY = (wa.Y + wa.Height) / sy - h;
        if (maxX < minX) maxX = minX;
        if (maxY < minY) maxY = minY;
        left = Math.Min(Math.Max(left, minX), maxX);
        top = Math.Min(Math.Max(top, minY), maxY);
    }
}
