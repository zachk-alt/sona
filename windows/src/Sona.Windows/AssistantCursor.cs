using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace Sona.Windows;

// Presentation only. Never moves the OS pointer or becomes an input destination.
internal sealed class AssistantCursor : Window, IDisposable
{
    private readonly Ellipse pulse = new() { Width = 28, Height = 28, Stroke = new SolidColorBrush(Color.FromRgb(56, 135, 255)), StrokeThickness = 2, Opacity = 0, RenderTransformOrigin = new Point(.5, .5) };
    private Point? lastPoint;
    private nint handle;
    internal static nint ActiveWindow { get; private set; }
    public AssistantCursor()
    {
        Width = Height = 44; Left = Top = -10000; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent; ShowActivated = false; ShowInTaskbar = false;
        Topmost = true; Focusable = false; IsHitTestVisible = false;
        var content = new Canvas { IsHitTestVisible = false };
        Canvas.SetLeft(pulse, -2); Canvas.SetTop(pulse, -2); content.Children.Add(pulse);
        content.Children.Add(new System.Windows.Shapes.Path
        {
            Data = Geometry.Parse("M 12,12 L 12,34 L 18,28 L 23,39 L 28,36 L 22,26 L 31,26 Z"),
            Fill = new SolidColorBrush(Color.FromRgb(56, 135, 255)), Stroke = Brushes.White, StrokeThickness = 1.5
        });
        var mark = new Image { Source = new BitmapImage(new Uri("pack://application:,,,/Assets/MenuIconRecording.png")), Width = 13, Height = 13 };
        Canvas.SetLeft(mark, 29); Canvas.SetTop(mark, 4); content.Children.Add(mark); Content = content;
        SourceInitialized += (_, _) =>
        {
            handle = new WindowInteropHelper(this).Handle; ActiveWindow = handle;
            Native.SetWindowLongPtr(handle, Native.GwlExStyle, Native.GetWindowLongPtr(handle, Native.GwlExStyle) | Native.WsExNoActivate | Native.WsExToolWindow | 0x20);
            CaptureNative.SetWindowDisplayAffinity(handle, 0x11);
            HwndSource.FromHwnd(handle)?.AddHook((nint h, int message, nint w, nint l, ref bool handled) =>
            {
                if (message == 0x84) { handled = true; return new nint(-1); } // HTTRANSPARENT.
                if (message == 0x21) { handled = true; return new nint(3); } // MA_NOACTIVATE.
                return 0;
            });
        };
    }
    public async Task MoveAsync(Native.Rect bounds, double x, double y, CancellationToken cancellation)
    {
        Point destination = new(bounds.Left + x * (bounds.Right - bounds.Left - 1), bounds.Top + y * (bounds.Bottom - bounds.Top - 1));
        Point start = lastPoint is Point old && old.X >= bounds.Left && old.X < bounds.Right && old.Y >= bounds.Top && old.Y < bounds.Bottom
            ? old : new Point(Math.Max(bounds.Left, destination.X - 42), Math.Max(bounds.Top, destination.Y - 25));
        cancellation.ThrowIfCancellationRequested(); pulse.Opacity = 0; Show(); Place(start);
        long began = Environment.TickCount64;
        while (true)
        {
            cancellation.ThrowIfCancellationRequested();
            double progress = Math.Min(1, (Environment.TickCount64 - began) / 180.0);
            double eased = progress * progress * (3 - 2 * progress);
            Place(new Point(start.X + (destination.X - start.X) * eased, start.Y + (destination.Y - start.Y) * eased));
            if (progress >= 1) break;
            await Task.Delay(16, cancellation);
        }
        lastPoint = destination;
    }
    private void Place(Point point)
    {
        var dpi = VisualTreeHelper.GetDpi(this);
        SetWindowPos(handle, new nint(-1), (int)Math.Round(point.X - 12 * dpi.DpiScaleX), (int)Math.Round(point.Y - 12 * dpi.DpiScaleY), 0, 0, 0x0001 | 0x0010); // NOSIZE | NOACTIVATE.
    }
    public async Task PulseAsync(CancellationToken cancellation)
    {
        // Called only after the native worker reports that its validated click was applied.
        cancellation.ThrowIfCancellationRequested(); Show();
        if (lastPoint is Point point) Place(point);
        for (int i = 0; i <= 8; i++)
        {
            cancellation.ThrowIfCancellationRequested(); double progress = i / 8.0;
            pulse.RenderTransform = new ScaleTransform(.55 + progress * .75, .55 + progress * .75); pulse.Opacity = 1 - progress;
            await Task.Delay(16, cancellation);
        }
        pulse.Opacity = 0;
    }
    public void Dispose() { Hide(); if (ActiveWindow == handle) ActiveWindow = 0; Close(); }
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
}
