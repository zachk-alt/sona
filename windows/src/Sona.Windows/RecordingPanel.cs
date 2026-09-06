using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Sona.Windows;

internal sealed class RecordingPanel : Window
{
    private readonly TextBlock title = new() { Foreground = Brushes.White, FontSize = 14, FontWeight = FontWeights.SemiBold };
    private readonly WaveMeter meter = new();
    private readonly TextBlock hint = new() { Foreground = new SolidColorBrush(Color.FromRgb(181, 193, 210)), FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center };
    public RecordingPanel()
    {
        Width = 340; Height = 142; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false; ShowActivated = false; Topmost = true; Focusable = false;
        Background = Brushes.Transparent;
        var content = new StackPanel { Margin = new Thickness(22, 15, 22, 12) };
        var heading = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        heading.Children.Add(new Image { Source = new BitmapImage(new Uri("pack://application:,,,/Assets/SonaAppIcon.png")), Width = 22, Height = 22, Margin = new Thickness(0, 0, 8, 0) });
        heading.Children.Add(title); title.VerticalAlignment = VerticalAlignment.Center;
        content.Children.Add(heading); content.Children.Add(meter); content.Children.Add(hint);
        content.Children.Add(new TextBlock { Text = "Sona  ·  Actual Intelligence Labs", Foreground = new SolidColorBrush(Color.FromRgb(146, 160, 178)), FontSize = 9, Margin = new Thickness(0, 7, 0, 0), HorizontalAlignment = HorizontalAlignment.Center });
        Content = new Border { Background = new SolidColorBrush(Color.FromArgb(218, 20, 26, 36)), BorderBrush = new SolidColorBrush(Color.FromArgb(150, 107, 169, 238)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(18), Child = content };
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            Native.SetWindowLongPtr(handle, Native.GwlExStyle, Native.GetWindowLongPtr(handle, Native.GwlExStyle) | Native.WsExNoActivate | Native.WsExToolWindow);
            HwndSource.FromHwnd(handle)?.AddHook((nint h, int m, nint w, nint l, ref bool handled) =>
            {
                if (m == 0x21) { handled = true; return new nint(3); } // MA_NOACTIVATE.
                return 0;
            });
            int dark = 1, corners = 2, acrylic = 3;
            Native.DwmSetWindowAttribute(handle, 20, ref dark, 4);
            Native.DwmSetWindowAttribute(handle, 33, ref corners, 4);
            Native.DwmSetWindowAttribute(handle, 38, ref acrylic, 4);
            var margins = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
            DwmExtendFrameIntoClientArea(handle, ref margins);
            if (HwndSource.FromHwnd(handle)?.CompositionTarget is { } target) target.BackgroundColor = Colors.Transparent;
        };
    }
    [StructLayout(LayoutKind.Sequential)] private struct Margins { public int Left, Right, Top, Bottom; }
    [DllImport("dwmapi.dll")] private static extern int DwmExtendFrameIntoClientArea(nint window, ref Margins margins);
    public void Recording(nint foreground, string shortcut)
    {
        title.Text = "Listening"; hint.Text = $"Tap {shortcut} to finish"; meter.Processing = false; meter.Level = 0;
        Show();
        var area = System.Windows.Forms.Screen.FromHandle(foreground).WorkingArea;
        var transform = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var origin = transform.Transform(new Point(area.Left, area.Top));
        var edge = transform.Transform(new Point(area.Right, area.Bottom));
        Left = origin.X + (edge.X - origin.X - Width) / 2; Top = origin.Y + 20;
        Native.ShowWindow(new WindowInteropHelper(this).Handle, 4); // SW_SHOWNOACTIVATE.
        meter.Start();
    }
    public void Processing(string text = "Transcribing") { title.Text = text; hint.Text = "Turning your voice into text"; meter.Processing = true; }
    public void SetLevel(float level) => meter.Level = level;
    public void Dismiss() { meter.Stop(); Hide(); }
}

internal sealed class WaveMeter : FrameworkElement
{
    private readonly Stopwatch clock = new();
    private readonly DispatcherTimer timer;
    private double smoothed;
    public double Level { get; set; }
    public bool Processing { get; set; }
    public WaveMeter()
    {
        Height = 48; Margin = new Thickness(0, 3, 0, 3);
        timer = new(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(1000.0 / 60) };
        timer.Tick += (_, _) => { smoothed += (Level - smoothed) * 0.22; InvalidateVisual(); };
    }
    public void Start() { clock.Restart(); timer.Start(); }
    public void Stop() { timer.Stop(); clock.Stop(); }
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        double t = clock.Elapsed.TotalSeconds;
        for (int i = 0; i < 29; i++)
        {
            double envelope = Math.Exp(-Math.Pow((i - 14) / 12.0, 2));
            double value = Processing ? 0.28 + 0.24 * Math.Sin(t * 5.5 - i * 0.35) : Math.Min(1, smoothed * 5) * (0.52 + 0.48 * Math.Sin(t * 8 + i * 0.85));
            double height = 3 + 35 * envelope * value;
            double x = ActualWidth / 2 + (i - 14) * 7 - 2;
            dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromRgb(88, 167, 255)), null, new Rect(x, (ActualHeight - height) / 2, 4, height), 2, 2);
        }
        if (Processing)
        {
            for (int i = 0; i < 2; i++)
            {
                double phase = t * 2 + i * Math.PI;
                dc.DrawEllipse(new SolidColorBrush(Color.FromRgb(166, 213, 255)), null,
                    new Point(ActualWidth / 2 + Math.Cos(phase) * 123, ActualHeight / 2 + Math.Sin(phase) * 18), 2.3, 2.3);
            }
        }
    }
}
