using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Sona.Core;

namespace Sona.Windows;

internal sealed class AssistantPanel : Window
{
    private readonly TextBlock hint = new() { Foreground = new SolidColorBrush(Color.FromArgb(170, 255, 255, 255)), FontSize = 10, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 9, 0, 0) };
    private readonly TextBlock answer = new() { TextWrapping = TextWrapping.Wrap, Foreground = Brushes.White, FontSize = 14 };
    private readonly WrapPanel actions = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0) };
    public AssistantPanel()
    {
        Width = RecordingPanel.PanelWidth; Height = 220; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; ShowInTaskbar = false; ShowActivated = false; Topmost = true; Focusable = false; Background = Brushes.Transparent;
        var content = new DockPanel { Margin = new Thickness(22, 15, 22, 15) };
        var heading = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        heading.Children.Add(new Image { Source = new BitmapImage(new Uri("pack://application:,,,/Assets/MenuIconRecording.png")), Width = 22, Height = 22, Margin = new Thickness(0, 0, 10, 0), HorizontalAlignment = HorizontalAlignment.Left });
        heading.Children.Add(new TextBlock { Text = "Sona", Foreground = Brushes.White, FontSize = 14, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        DockPanel.SetDock(heading, Dock.Top); content.Children.Add(heading); DockPanel.SetDock(hint, Dock.Bottom); content.Children.Add(hint); DockPanel.SetDock(actions, Dock.Bottom); content.Children.Add(actions);
        content.Children.Add(new ScrollViewer { Content = answer, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false });
        Content = new Border { Background = new SolidColorBrush(Color.FromArgb(218, 20, 26, 36)), BorderBrush = new SolidColorBrush(Color.FromArgb(150, 107, 169, 238)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(18), Child = content };
        SourceInitialized += (_, _) =>
        {
            nint hwnd = new WindowInteropHelper(this).Handle;
            Native.SetWindowLongPtr(hwnd, Native.GwlExStyle, Native.GetWindowLongPtr(hwnd, Native.GwlExStyle) | Native.WsExNoActivate | Native.WsExToolWindow);
            CaptureNative.SetWindowDisplayAffinity(hwnd, 0x11);
            HwndSource.FromHwnd(hwnd)?.AddHook((nint h, int m, nint w, nint l, ref bool handled) => { if (m == 0x21) { handled = true; return 3; } return 0; });
            int dark = 1, corners = 2, acrylic = 3;
            Native.DwmSetWindowAttribute(hwnd, 20, ref dark, 4); Native.DwmSetWindowAttribute(hwnd, 33, ref corners, 4); Native.DwmSetWindowAttribute(hwnd, 38, ref acrylic, 4);
        };
    }
    private static Button Button(string label, Action action)
    {
        var button = new Button { Content = label, Focusable = false, IsTabStop = false, Padding = new Thickness(10, 6, 10, 6), Margin = new Thickness(0, 0, 8, 0) };
        button.Click += (_, _) => { try { action(); } catch { } }; return button;
    }
    public void SetShortcutLabel(string label) => hint.Text = $"Hold {label} to ask more · Release to send · Tap to dismiss";
    public void Present(nint foreground, AssistantReply reply)
    {
        hint.Visibility = Visibility.Visible;
        answer.Text = reply.Status == "ok" && reply.Kind == "answer" && !string.IsNullOrWhiteSpace(reply.Text) ? reply.Text : reply.FailureMessage; actions.Children.Clear();
        actions.Children.Add(Button("Copy", () => Clipboard.SetText(answer.Text)));
        FitResponse(); Show(); RecordingPanel.Position(this, foreground);
    }
    private void FitResponse()
    {
        answer.Measure(new Size(Width - 64, double.PositiveInfinity));
        actions.Measure(new Size(Width - 44, double.PositiveInfinity));
        hint.Measure(new Size(Width - 44, double.PositiveInfinity));
        Height = Math.Clamp(72 + answer.DesiredSize.Height + actions.DesiredSize.Height + hint.DesiredSize.Height, 190, 280);
    }
    public void Suspend() => Hide();
    public void Resume() { if (!string.IsNullOrEmpty(answer.Text)) Show(); }
    public void Clear() { answer.Text = ""; actions.Children.Clear(); Hide(); }
}
