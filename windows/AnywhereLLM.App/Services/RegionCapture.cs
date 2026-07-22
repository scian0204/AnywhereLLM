using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using AnywhereLLM.Interop;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace AnywhereLLM.Services;

/// Interactive screen-region capture — the Win+Shift+S analog, mirroring the macOS
/// `screencapture -i` flow. Grabs the whole virtual desktop up front (a clean,
/// undimmed frozen frame), shows a dimmed selection overlay, then crops the frozen
/// frame to the dragged rectangle. Returns PNG bytes, or null if cancelled.
///
/// Capture correctness is DPI-independent: the crop rect comes from GetCursorPos
/// (physical pixels) and CopyFromScreen also works in physical pixels, so no
/// DIP↔physical math sits on the capture path. Only the overlay's coverage relies
/// on SetWindowPos to the virtual-screen physical bounds.
/// ponytail: cropping from a pre-captured frame avoids the overlay showing up in the
/// result and any hide-then-capture repaint race — standard freeze-frame approach.
public static class RegionCapture
{
    /// Runs modally on the UI (STA) thread. Call from the Dispatcher.
    public static byte[]? CaptureRegion()
    {
        var vs = Forms.SystemInformation.VirtualScreen; // physical px, may have negative origin
        if (vs.Width < 1 || vs.Height < 1) return null;

        Drawing.Bitmap full;
        try
        {
            full = new Drawing.Bitmap(vs.Width, vs.Height, Drawing.Imaging.PixelFormat.Format32bppArgb);
            using var g = Drawing.Graphics.FromImage(full);
            g.CopyFromScreen(vs.Left, vs.Top, 0, 0,
                new Drawing.Size(vs.Width, vs.Height), Drawing.CopyPixelOperation.SourceCopy);
        }
        catch { return null; }

        using (full)
        {
            var overlay = new OverlayWindow();
            bool ok = overlay.ShowDialog() == true;
            if (!ok || overlay.SelectionPhysical is not { } r || r.Width < 1 || r.Height < 1) return null;

            // Screen coords → bitmap coords (bitmap origin is the virtual-screen top-left).
            var crop = new Drawing.Rectangle(r.X - vs.Left, r.Y - vs.Top, r.Width, r.Height);
            crop.Intersect(new Drawing.Rectangle(0, 0, full.Width, full.Height));
            if (crop.Width < 1 || crop.Height < 1) return null;

            try
            {
                using var sub = full.Clone(crop, full.PixelFormat);
                using var ms = new MemoryStream();
                sub.Save(ms, Drawing.Imaging.ImageFormat.Png);
                return ms.ToArray();
            }
            catch { return null; }
        }
    }

    /// Fullscreen dimmed overlay with a live drag rectangle. The drag rect for the
    /// crop is read from GetCursorPos (physical); the on-screen rectangle is drawn in
    /// the overlay's DIP space (visual feedback only).
    private sealed class OverlayWindow : Window
    {
        public Drawing.Rectangle? SelectionPhysical { get; private set; }

        private readonly Canvas _canvas = new();
        private readonly System.Windows.Shapes.Rectangle _rect;
        private bool _dragging;
        private System.Windows.Point _startDip;
        private NativeMethods.POINT _startPhysical;

        public OverlayWindow()
        {
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = new SolidColorBrush(Color.FromArgb(80, 0, 0, 0)); // dim, but hit-testable
            ShowInTaskbar = false;
            Topmost = true;
            ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.Manual;
            Cursor = Cursors.Cross;

            _rect = new System.Windows.Shapes.Rectangle
            {
                Stroke = Brushes.DeepSkyBlue,
                StrokeThickness = 1.5,
                Fill = new SolidColorBrush(Color.FromArgb(40, 0, 150, 255)),
                Visibility = Visibility.Collapsed,
            };
            _canvas.Children.Add(_rect);
            Content = _canvas;

            MouseLeftButtonDown += OnDown;
            MouseMove += OnMove;
            MouseLeftButtonUp += OnUp;
            MouseRightButtonDown += (_, _) => Cancel();
            KeyDown += (_, e) => { if (e.Key == Key.Escape) Cancel(); };
            Loaded += (_, _) => { Activate(); Focus(); }; // so Esc reaches KeyDown
        }

        protected override void OnSourceInitialized(EventArgs e)
        {
            base.OnSourceInitialized(e);
            // Cover the whole virtual desktop in physical pixels.
            var vs = Forms.SystemInformation.VirtualScreen;
            var hwnd = new WindowInteropHelper(this).Handle;
            NativeMethods.SetWindowPos(hwnd, IntPtr.Zero, vs.Left, vs.Top, vs.Width, vs.Height,
                NativeMethods.SWP_NOZORDER | NativeMethods.SWP_NOACTIVATE);
        }

        private void OnDown(object sender, MouseButtonEventArgs e)
        {
            _dragging = true;
            _startDip = e.GetPosition(_canvas);
            NativeMethods.GetCursorPos(out _startPhysical);
            Canvas.SetLeft(_rect, _startDip.X);
            Canvas.SetTop(_rect, _startDip.Y);
            _rect.Width = 0;
            _rect.Height = 0;
            _rect.Visibility = Visibility.Visible;
            CaptureMouse();
        }

        private void OnMove(object sender, MouseEventArgs e)
        {
            if (!_dragging) return;
            var p = e.GetPosition(_canvas);
            Canvas.SetLeft(_rect, Math.Min(p.X, _startDip.X));
            Canvas.SetTop(_rect, Math.Min(p.Y, _startDip.Y));
            _rect.Width = Math.Abs(p.X - _startDip.X);
            _rect.Height = Math.Abs(p.Y - _startDip.Y);
        }

        private void OnUp(object sender, MouseButtonEventArgs e)
        {
            if (!_dragging) return;
            _dragging = false;
            ReleaseMouseCapture();
            NativeMethods.GetCursorPos(out var end);
            int x = Math.Min(_startPhysical.X, end.X);
            int y = Math.Min(_startPhysical.Y, end.Y);
            int w = Math.Abs(end.X - _startPhysical.X);
            int h = Math.Abs(end.Y - _startPhysical.Y);
            SelectionPhysical = new Drawing.Rectangle(x, y, w, h);
            DialogResult = true; // closes ShowDialog
        }

        private void Cancel()
        {
            SelectionPhysical = null;
            DialogResult = false;
        }
    }
}
