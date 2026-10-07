using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Sona.Core;

namespace Sona.Windows;

/// The floating dictation panel, drawn to match the Mac panel (Sources/Murmur/StatusBarController.swift
/// and WaveView.swift). The window is a nonactivating layered window: the glass, rim, shadows, bars and
/// lights are all drawn by Sona, so the 26 DIP rounded glass and its soft glow margin are exact.
internal sealed class RecordingPanel : Window
{
    internal const double PanelWidth = PanelGeometry.Width, PanelHeight = PanelGeometry.Height;
    private readonly PanelSurface surface = new();
    private readonly BarMotion motion = new();
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly DispatcherTimer errorTimer = new() { Interval = TimeSpan.FromSeconds(PanelTiming.ErrorSeconds) };
    private LightScript? script;
    private double lightsStartedAt, dismissStartedAt = -1, dismissLift, lastFrame = -1;
    private TimeSpan lastRenderingTime = TimeSpan.MinValue;
    private int originX, originY;
    private bool placed, framesRunning;
    private nint lastForeground, handle;

    public RecordingPanel()
    {
        Width = PanelWidth; Height = PanelHeight; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent;
        ShowInTaskbar = false; ShowActivated = false; Topmost = true; Focusable = false;
        Content = surface;
        errorTimer.Tick += (_, _) => { errorTimer.Stop(); surface.SetError(null); Dismiss(); };
        _ = Task.Run(PanelSurface.WarmUp);
        SourceInitialized += (_, _) =>
        {
            handle = new WindowInteropHelper(this).Handle;
            // Click-through as well: the soft margin covers caption buttons at the top right, and the panel has nothing to click.
            Native.SetWindowLongPtr(handle, Native.GwlExStyle, Native.GetWindowLongPtr(handle, Native.GwlExStyle) | Native.WsExNoActivate | Native.WsExToolWindow | Native.WsExTransparent);
            HwndSource.FromHwnd(handle)?.AddHook((nint h, int m, nint w, nint l, ref bool handled) =>
            {
                if (m == 0x21) { handled = true; return new nint(3); } // MA_NOACTIVATE.
                return 0;
            });
        };
    }

    /// StatusBarController.showRecording: instant, bars from wherever they are, lights off.
    public void Recording(nint foreground)
    {
        errorTimer.Stop(); surface.SetError(null);
        CancelDismissal();
        Present(foreground);
        motion.StartRecording();
        StopLights();
        StartFrames();
    }

    /// StatusBarController.showProcessing: same window, the travelling wave and the rim lights.
    public void Processing(nint foreground = 0)
    {
        errorTimer.Stop(); surface.SetError(null);
        CancelDismissal();
        Present(foreground);
        motion.StartProcessing();
        if (script == null) { script = LightScript.Generate(new Random()); lightsStartedAt = Now; }
        surface.LightsVisible = true;
        StartFrames();
    }

    /// StatusBarController.showError: the message replaces the bars for three seconds, then the panel fades.
    public void ShowError(string message, nint foreground = 0)
    {
        Recording(foreground);
        surface.SetError(message);
        errorTimer.Start();
        // The message is drawn, so also hand it to screen readers (Narrator announces UIA notifications).
        try
        {
            var peer = UIElementAutomationPeer.FromElement(surface) ?? UIElementAutomationPeer.CreatePeerForElement(surface) ?? new FrameworkElementAutomationPeer(surface);
            peer.RaiseNotificationEvent(AutomationNotificationKind.Other, AutomationNotificationProcessing.ImportantMostRecent, message, "SonaPanelMessage");
        }
        catch (Exception e) when (e is not OutOfMemoryException) { }
    }

    /// Recordings only forward bands while dictating, like the Mac.
    public void SetSpectrum(float[] bands) => motion.SetSpectrum(bands);

    /// StatusBarController.showIdle: a 0.36 s smoothstep fade with a 6 DIP lift, cancelled by any new show.
    public void Dismiss()
    {
        if (!IsVisible) { FinishDismissal(); return; }
        if (dismissStartedAt >= 0) return;
        dismissStartedAt = Now;
        dismissLift = SystemParameters.ClientAreaAnimation ? PanelTiming.DismissLift : 0;
        StartFrames();
    }

    /// Hide at once, for quitting and tests.
    public void HideNow() => FinishDismissal();

    /// Creates the hidden window and draws the static layers ahead of the first dictation.
    public void Prepare()
    {
        new WindowInteropHelper(this).EnsureHandle();
        surface.Configure(Scale, PanelLook.Current());
    }

    private double Now => clock.Elapsed.TotalSeconds;
    private double Scale => VisualTreeHelper.GetDpi(this).DpiScaleX;

    private void Present(nint foreground)
    {
        if (foreground != 0) lastForeground = foreground;
        new WindowInteropHelper(this).EnsureHandle();
        var look = PanelLook.Current();
        surface.Configure(Scale, look);
        Place();
        if (!IsVisible) Show();
        Native.ShowWindow(handle, 4); // SW_SHOWNOACTIVATE: raise without activating.
        Place(); // Settles a move onto a monitor with another scale.
        surface.Configure(Scale, look);
    }

    // The Mac fallback placement (AssistantPanelPlacement.origin without a menu anchor), in device
    // pixels on the monitor of the foreground window: glass center 180 DIP from the monitor's right
    // edge, glass top 6 DIP below the top of the work area, kept 8 DIP inside the work area.
    private void Place()
    {
        nint window = lastForeground != 0 && Native.IsWindow(lastForeground) ? lastForeground : Native.GetForegroundWindow();
        nint monitor = MonitorFromWindow(window, 2);
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (monitor == 0 || !GetMonitorInfo(monitor, ref info)) return;
        double k = GetDpiForMonitor(monitor, 0, out uint dpi, out _) == 0 && dpi > 0 ? dpi / 96.0 : Scale;
        double glassWidth = PanelGeometry.GlassWidth * k, glassHeight = PanelGeometry.GlassHeight * k, margin = PanelGeometry.Margin * k;
        double minX = info.Work.Left + 8 * k, maxX = info.Work.Right - 8 * k - glassWidth;
        double minTop = info.Work.Top + 6 * k, maxTop = info.Work.Bottom - 8 * k - glassHeight;
        double glassX = Math.Min(maxX, Math.Max(minX, info.Monitor.Right - 180 * k - glassWidth / 2));
        double glassTop = Math.Max(info.Work.Top, Math.Min(minTop, maxTop));
        originX = (int)Math.Round(glassX - margin); originY = (int)Math.Round(glassTop - margin); placed = true;
        uint before = GetDpiForWindow(handle);
        MoveTo(handle, originX, originY, raise: true);
        if (GetDpiForWindow(handle) != before) MoveTo(handle, originX, originY, raise: true);
    }

    // SWP_NOSIZE | SWP_NOACTIVATE, plus HWND_TOPMOST when raising or SWP_NOZORDER for a plain move.
    private static void MoveTo(nint handle, int x, int y, bool raise = false) =>
        SetWindowPos(handle, raise ? -1 : 0, x, y, 0, 0, 0x0001 | 0x0010 | (raise ? 0u : 0x0004u));

    private void CancelDismissal()
    {
        if (dismissStartedAt < 0) return;
        dismissStartedAt = -1; Opacity = 1;
        if (placed) MoveTo(handle, originX, originY);
    }

    private void FinishDismissal()
    {
        errorTimer.Stop(); surface.SetError(null);
        dismissStartedAt = -1;
        if (IsVisible) Hide();
        StopFrames(); motion.Stop(); StopLights();
        Opacity = 1;
        if (placed && handle != 0) MoveTo(handle, originX, originY);
    }

    private void StopLights() { script = null; surface.LightsVisible = false; }

    private void StartFrames()
    {
        if (framesRunning) return;
        framesRunning = true; lastFrame = -1; lastRenderingTime = TimeSpan.MinValue;
        CompositionTarget.Rendering += OnRendering;
    }

    private void StopFrames()
    {
        if (!framesRunning) return;
        framesRunning = false;
        CompositionTarget.Rendering -= OnRendering;
    }

    private void OnRendering(object? sender, EventArgs e)
    {
        // Rendering can fire more than once per frame; advance once per composed frame.
        if (e is RenderingEventArgs args) { if (args.RenderingTime == lastRenderingTime) return; lastRenderingTime = args.RenderingTime; }
        double now = Now, dt = lastFrame < 0 ? 1.0 / 60 : now - lastFrame;
        lastFrame = now;
        motion.Advance(dt);
        surface.Update(motion, script?.At(now - lightsStartedAt));
        if (dismissStartedAt < 0) return;
        double progress = Math.Clamp((now - dismissStartedAt) / PanelTiming.DismissSeconds, 0, 1), eased = PanelTiming.Smoothstep(progress);
        Opacity = 1 - eased;
        if (placed) MoveTo(handle, originX, originY - (int)Math.Round(dismissLift * Scale * eased));
        if (progress >= 1) FinishDismissal();
    }

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi);
        surface.Configure(newDpi.DpiScaleX, PanelLook.Current());
    }

    protected override void OnClosed(EventArgs e)
    {
        errorTimer.Stop(); StopFrames();
        base.OnClosed(e);
    }

    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo { public int Size; public Native.Rect Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] private static extern nint MonitorFromWindow(nint window, uint flags);
    [DllImport("user32.dll")] private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(nint monitor, int type, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
}

/// The Windows app theme and the accessibility settings the panel follows.
internal readonly record struct PanelLook(bool Light, bool Transparency, bool HighContrast, Color Window, Color Text, Color Highlight)
{
    public static PanelLook Current() => new(Personalize("AppsUseLightTheme", true), Personalize("EnableTransparency", true),
        SystemParameters.HighContrast, SystemColors.WindowColor, SystemColors.WindowTextColor, SystemColors.HighlightColor);

    public static PanelLook Preview(bool light) => new(light, true, false, Colors.White, Colors.Black, Colors.Blue);

    private static bool Personalize(string name, bool fallback)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue(name) is int value ? value != 0 : fallback;
        }
        catch { return fallback; }
    }
}

/// Window and glass geometry in DIPs (one Mac point is one DIP).
internal static class PanelGeometry
{
    public const double Width = 352, Height = 156, Margin = 26, GlassWidth = 300, GlassHeight = 104, Radius = 26;
    public const double CenterX = Margin + GlassWidth / 2, CenterY = Margin + GlassHeight / 2;
    public const double BarCenterY = Margin + 44;

    /// Distance inside the rounded glass outline in DIPs, negative outside (window coordinates).
    public static double Depth(double x, double y)
    {
        double qx = Math.Abs(x - CenterX) - (GlassWidth / 2 - Radius);
        double qy = Math.Abs(y - CenterY) - (GlassHeight / 2 - Radius);
        double dx = Math.Max(qx, 0), dy = Math.Max(qy, 0);
        return Radius - Math.Sqrt(dx * dx + dy * dy) - Math.Min(Math.Max(qx, qy), 0);
    }
}

/// Draws the panel. The static layers (shadow, bloom, glass, credit, rim and edge light) are computed
/// once per scale and look; the bars and the rim lights are written into reused bitmaps each frame.
internal sealed class PanelSurface : FrameworkElement
{
    private static readonly Color Blue = Color.FromRgb(15, 92, 216);
    private const double BarSigma = 2.4, GlowReach = 8.4, HaloReach = 13;
    private const int MaxColumnBars = 6;
    private static readonly Lazy<(float[] Depth, float[] Bloom)> Shadows = new(BuildShadows);
    private const int ShadowTopPad = 8, ShadowWidth = 352, ShadowHeight = 164;

    private double scale;
    private PanelLook look;
    private bool configured, lightsVisible;
    private BitmapSource? under, over;
    private WriteableBitmap? bars, lights;
    private int[] barPixels = [], lightPixels = [];
    private int barsX0, barsY0, barsWidth, barsHeight, pixelWidth, pixelHeight, dirtyTop, dirtyBottom = -1;
    private int[] columnBars = [];
    private float[] columnGlow = [], verticalGlow = [];
    private double[] columnX = [], rowY = [];
    private readonly double[] barHeight = new double[BarMotion.BarCount], barAlpha = new double[BarMotion.BarCount], glowAlpha = new double[BarMotion.BarCount];
    private readonly double[] drawnHeight = new double[BarMotion.BarCount], drawnAlpha = new double[BarMotion.BarCount], drawnGlow = new double[BarMotion.BarCount];
    private bool barsDrawn;
    private int[] columnTop = [], columnBottom = [];
    // Ring pixels sorted by bearing, so a frame touches only the arcs under the lights and the arcs lit last frame.
    private int[] ringIndex = [];
    private short[] ringX = [], ringY = [];
    private float[] ringBearing = [], ringCore = [], ringHalo = [];
    private readonly List<(int Start, int End)> litArcs = [];
    private string? error;
    private FormattedText? errorText;

    public PanelSurface()
    {
        Width = PanelGeometry.Width; Height = PanelGeometry.Height;
        IsHitTestVisible = false; Focusable = false;
    }

    public static void WarmUp() => _ = Shadows.Value;

    public bool LightsVisible
    {
        get => lightsVisible;
        set { if (lightsVisible == value) return; lightsVisible = value; InvalidateVisual(); }
    }

    public void SetError(string? message)
    {
        if (error == message) return;
        error = message; errorText = null; InvalidateVisual();
    }

    public void Configure(double newScale, PanelLook newLook)
    {
        if (!(newScale > 0)) newScale = 1;
        if (configured && newScale == scale && newLook == look) return;
        scale = newScale; look = newLook; configured = true; errorText = null;
        pixelWidth = (int)Math.Round(PanelGeometry.Width * scale); pixelHeight = (int)Math.Round(PanelGeometry.Height * scale);
        under = BuildUnder(); over = BuildOver();
        BuildBarLayout(); BuildRing();
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        if (!configured || under == null || over == null || bars == null || lights == null) return;
        var full = new Rect(0, 0, PanelGeometry.Width, PanelGeometry.Height);
        dc.DrawImage(under, full);
        if (error == null) dc.DrawImage(bars, new Rect(barsX0 / scale, barsY0 / scale, barsWidth / scale, barsHeight / scale));
        else
        {
            errorText ??= ErrorText(error);
            dc.DrawText(errorText, new Point(PanelGeometry.Margin + 12, PanelGeometry.Margin + 26));
        }
        dc.DrawImage(over, full);
        if (lightsVisible) dc.DrawImage(lights, full);
    }

    private FormattedText ErrorText(string message)
    {
        var text = new FormattedText(message, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal), 13, LabelBrush(), scale)
        { MaxTextWidth = 276, MaxTextHeight = 36, TextAlignment = TextAlignment.Center, Trimming = TextTrimming.CharacterEllipsis };
        return text;
    }

    private Brush LabelBrush()
    {
        var brush = new SolidColorBrush(look.HighContrast ? look.Text : look.Light ? Color.FromArgb(217, 0, 0, 0) : Color.FromArgb(217, 255, 255, 255));
        brush.Freeze();
        return brush;
    }

    // Bars and their glow. Every bar, its glow and the haze between bars share one color, so the
    // composite is that color at alpha 1 - product(1 - alpha), the same as the Mac's ordered drawing.
    public void Update(BarMotion motion, LightPose? pose)
    {
        if (!configured || bars == null || lights == null) return;
        if (error == null) UpdateBars(motion);
        if (lightsVisible && pose is { } p) UpdateLights(p);
    }

    private void UpdateBars(BarMotion motion)
    {
        double maxHalf = 0, heightStep = 1 / (255 * scale); // An edge moves about half a level per heightStep.
        bool same = barsDrawn;
        for (int i = 0; i < BarMotion.BarCount; i++)
        {
            double h = motion.Height(i), a = motion.Alpha(i);
            barHeight[i] = h; maxHalf = Math.Max(maxHalf, h / 2);
            barAlpha[i] = look.HighContrast ? 1 : a;
            // The glow is the bar's own shape blurred; a pill is smaller than its box by (4 - pi) DIP squared.
            glowAlpha[i] = look.HighContrast || motion.Mode == BarMode.Idle ? 0 : 0.5 * a * (2 * h - (4 - Math.PI)) / (2 * h);
            same = same && Math.Abs(h - drawnHeight[i]) < heightStep && Math.Abs(barAlpha[i] - drawnAlpha[i]) < 0.002 && Math.Abs(glowAlpha[i] - drawnGlow[i]) < 0.002;
        }
        // Silence and steady bars: nothing visibly moved since the last drawn frame (under about one level).
        if (same) return;
        Array.Copy(barHeight, drawnHeight, barHeight.Length); Array.Copy(barAlpha, drawnAlpha, barAlpha.Length); Array.Copy(glowAlpha, drawnGlow, glowAlpha.Length);
        barsDrawn = true;
        int top = Math.Max(0, (int)Math.Floor((PanelGeometry.BarCenterY - maxHalf - GlowReach) * scale) - barsY0);
        int bottom = Math.Min(barsHeight - 1, (int)Math.Ceiling((PanelGeometry.BarCenterY + maxHalf + GlowReach) * scale) - barsY0);
        for (int i = 0; i < BarMotion.BarCount; i++)
        {
            double y0 = PanelGeometry.BarCenterY - barHeight[i] / 2, y1 = PanelGeometry.BarCenterY + barHeight[i] / 2;
            int offset = i * barsHeight;
            for (int r = top; r <= bottom; r++)
                verticalGlow[offset + r] = (float)(PanelPaint.PhiFast((rowY[r] - y0) / BarSigma) - PanelPaint.PhiFast((rowY[r] - y1) / BarSigma));
        }
        // Each column only spans the rows its own bars (at most six) and their glow can reach.
        for (int c = 0; c < barsWidth; c++)
        {
            double reach = 0;
            for (int k = 0; k < MaxColumnBars; k++)
            {
                int i = columnBars[c * MaxColumnBars + k];
                if (i < 0) break;
                reach = Math.Max(reach, barHeight[i] / 2);
            }
            columnTop[c] = (int)Math.Floor((PanelGeometry.BarCenterY - reach - GlowReach) * scale) - barsY0;
            columnBottom[c] = (int)Math.Ceiling((PanelGeometry.BarCenterY + reach + GlowReach) * scale) - barsY0;
        }
        Color color = look.HighContrast ? look.Highlight : Blue;
        int firstRow = dirtyBottom < 0 ? top : Math.Min(top, dirtyTop), lastRow = dirtyBottom < 0 ? bottom : Math.Max(bottom, dirtyBottom);
        double half = 0.5 / scale;
        for (int r = firstRow; r <= lastRow; r++)
        {
            int row = r * barsWidth;
            if (r < top || r > bottom) { Array.Clear(barPixels, row, barsWidth); continue; }
            double y = rowY[r];
            for (int c = 0; c < barsWidth; c++)
            {
                if (r < columnTop[c] || r > columnBottom[c]) { barPixels[row + c] = 0; continue; }
                double keep = 1, x = columnX[c];
                for (int k = 0; k < MaxColumnBars; k++)
                {
                    int slot = c * MaxColumnBars + k, i = columnBars[slot];
                    if (i < 0) break;
                    keep *= 1 - glowAlpha[i] * columnGlow[slot] * verticalGlow[i * barsHeight + r];
                    double center = PanelGeometry.Margin + 2 + BarMotion.BarPitch * i;
                    if (Math.Abs(x - center) < 1 + half)
                    {
                        double qx = Math.Abs(x - center), qy = Math.Abs(y - PanelGeometry.BarCenterY) - (barHeight[i] / 2 - 1);
                        double ox = Math.Max(qx, 0), oy = Math.Max(qy, 0);
                        double distance = Math.Sqrt(ox * ox + oy * oy) + Math.Min(Math.Max(qx, qy), 0) - 1;
                        double coverage = Math.Clamp(0.5 - distance * scale, 0, 1);
                        keep *= 1 - barAlpha[i] * coverage;
                    }
                }
                barPixels[row + c] = PanelPaint.Pack(color, 1 - keep);
            }
        }
        dirtyTop = top; dirtyBottom = bottom;
        if (lastRow >= firstRow)
            bars!.WritePixels(new Int32Rect(0, firstRow, barsWidth, lastRow - firstRow + 1), barPixels, barsWidth * 4, 0, firstRow);
    }

    // Two white lights and a pale blue tail on the outline (StatusBarController Formation), drawn as the
    // halo (2 DIP band plus a sigma 5 blur at 0.55) under the core (1.6 DIP band).
    private void UpdateLights(LightPose pose)
    {
        double lead = Turn(LightScript.RestBearing - pose.One * 180 / Math.PI), follow = Turn(LightScript.RestBearing - pose.Two * 180 / Math.PI);
        bool contrast = look.HighContrast;
        double hr = contrast ? look.Highlight.R / 255.0 : 1, hg = contrast ? look.Highlight.G / 255.0 : 1, hb = contrast ? look.Highlight.B / 255.0 : 1;
        double tr = contrast ? hr : 0.72, tg = contrast ? hg : 0.84, tb = contrast ? hb : 1;
        int minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1;
        void Touch(int n)
        {
            int x = ringX[n], y = ringY[n];
            if (x < minX) minX = x; if (x > maxX) maxX = x;
            if (y < minY) minY = y; if (y > maxY) maxY = y;
        }
        // Clear last frame's arcs, then draw this frame's (overlaps simply draw the same pixel twice).
        foreach (var (start, end) in litArcs)
            for (int n = start; n < end; n++) { lightPixels[ringIndex[n]] = 0; Touch(n); }
        litArcs.Clear();
        AddArcs(lead, pose.Tail > 0 ? 0.14 * 360 : 0.05 * 360);
        AddArcs(follow, 0.05 * 360);
        foreach (var (start, end) in litArcs)
            for (int n = start; n < end; n++)
            {
                Touch(n);
                double bearing = ringBearing[n];
                double tail = 0.5 * Wedge(bearing, lead, 0.14) * pose.Tail, second = 0.85 * Wedge(bearing, follow, 0.05), first = Wedge(bearing, lead, 0.05);
                if (tail <= 0 && second <= 0 && first <= 0) { lightPixels[ringIndex[n]] = 0; continue; }
                double r = tr * tail, g = tg * tail, b = tb * tail, a = tail;
                r = hr * second + r * (1 - second); g = hg * second + g * (1 - second); b = hb * second + b * (1 - second); a = second + a * (1 - second);
                r = hr * first + r * (1 - first); g = hg * first + g * (1 - first); b = hb * first + b * (1 - first); a = first + a * (1 - first);
                // Core over halo: alpha a*core, then a*halo through what the core leaves.
                double core = ringCore[n], m = core + ringHalo[n] * (1 - a * core);
                lightPixels[ringIndex[n]] = PanelPaint.PackPremultiplied(r * m, g * m, b * m, a * m);
            }
        if (maxX >= minX)
            lights!.WritePixels(new Int32Rect(minX, minY, maxX - minX + 1, maxY - minY + 1), lightPixels, pixelWidth * 4, minX, minY);
    }

    // The ring entries whose bearing lies within halfWidth degrees of center, as index ranges of the sorted ring.
    private void AddArcs(double center, double halfWidth)
    {
        double lo = center - halfWidth, hi = center + halfWidth;
        if (lo < 0) { AddArc(lo + 360, 360); AddArc(0, hi); }
        else if (hi > 360) { AddArc(lo, 360); AddArc(0, hi - 360); }
        else AddArc(lo, hi);
    }

    private void AddArc(double lo, double hi)
    {
        int start = LowerBound(lo), end = LowerBound(hi);
        while (end < ringBearing.Length && ringBearing[end] <= hi) end++;
        if (end > start) litArcs.Add((start, end));
    }

    private int LowerBound(double value)
    {
        int lo = 0, hi = ringBearing.Length;
        while (lo < hi)
        {
            int mid = (lo + hi) >>> 1;
            if (ringBearing[mid] < value) lo = mid + 1; else hi = mid;
        }
        return lo;
    }

    private static double Turn(double degrees)
    {
        double turned = degrees % 360;
        return turned < 0 ? turned + 360 : turned;
    }

    // Conic light profile around its center bearing (StatusBarController.arcLight), both in [0, 360).
    private static double Wedge(double bearing, double center, double halfWidth)
    {
        double diff = bearing - center;
        if (diff < 0) diff += 360;
        double u = (diff > 180 ? 360 - diff : diff) / 360;
        if (u >= halfWidth) return 0;
        return u >= 0.35 * halfWidth ? 0.3 * (halfWidth - u) / (0.65 * halfWidth) : 0.3 + 0.7 * (0.35 * halfWidth - u) / (0.35 * halfWidth);
    }

    private void BuildBarLayout()
    {
        barsX0 = (int)Math.Floor((PanelGeometry.Margin + 1 - GlowReach) * scale);
        barsY0 = (int)Math.Floor((PanelGeometry.BarCenterY - BarMotion.MaxHeight / 2 - GlowReach) * scale);
        barsWidth = (int)Math.Ceiling((PanelGeometry.Margin + 299 + GlowReach) * scale) - barsX0;
        barsHeight = (int)Math.Ceiling((PanelGeometry.BarCenterY + BarMotion.MaxHeight / 2 + GlowReach) * scale) - barsY0;
        barPixels = new int[barsWidth * barsHeight];
        verticalGlow = new float[BarMotion.BarCount * barsHeight];
        columnX = new double[barsWidth]; rowY = new double[barsHeight];
        for (int r = 0; r < barsHeight; r++) rowY[r] = (barsY0 + r + 0.5) / scale;
        columnBars = new int[barsWidth * MaxColumnBars]; columnGlow = new float[barsWidth * MaxColumnBars];
        columnTop = new int[barsWidth]; columnBottom = new int[barsWidth];
        Array.Fill(columnBars, -1);
        for (int c = 0; c < barsWidth; c++)
        {
            double x = columnX[c] = (barsX0 + c + 0.5) / scale;
            int k = 0;
            for (int i = 0; i < BarMotion.BarCount && k < MaxColumnBars; i++)
            {
                double left = PanelGeometry.Margin + 1 + BarMotion.BarPitch * i, right = left + BarMotion.BarWidth;
                if (x < left - GlowReach || x > right + GlowReach) continue;
                columnBars[c * MaxColumnBars + k] = i;
                columnGlow[c * MaxColumnBars + k] = (float)(PanelPaint.Phi((x - left) / BarSigma) - PanelPaint.Phi((x - right) / BarSigma));
                k++;
            }
        }
        bars = new WriteableBitmap(barsWidth, barsHeight, 96 * scale, 96 * scale, PixelFormats.Pbgra32, null);
        dirtyBottom = -1; barsDrawn = false;
    }

    private void BuildRing()
    {
        lightPixels = new int[pixelWidth * pixelHeight];
        lights = new WriteableBitmap(pixelWidth, pixelHeight, 96 * scale, 96 * scale, PixelFormats.Pbgra32, null);
        var index = new List<int>(); var bearing = new List<float>(); var core = new List<float>(); var halo = new List<float>();
        double w = 1 / scale;
        for (int py = 0; py < pixelHeight; py++)
            for (int px = 0; px < pixelWidth; px++)
            {
                double x = (px + 0.5) / scale, y = (py + 0.5) / scale, d = PanelGeometry.Depth(x, y);
                if (Math.Abs(d) > HaloReach) continue;
                double band = PanelPaint.Band(d, w, -1, 1);
                double glow = band + (1 - band) * (PanelPaint.Phi((Math.Abs(d) + 1) / 5) - PanelPaint.Phi((Math.Abs(d) - 1) / 5));
                double b = Math.Atan2(x - PanelGeometry.CenterX, -(y - PanelGeometry.CenterY)) * 180 / Math.PI;
                index.Add(py * pixelWidth + px);
                bearing.Add((float)(b < 0 ? b + 360 : b));
                core.Add((float)PanelPaint.Band(d, w, -0.8, 0.8));
                halo.Add(look.HighContrast ? 0 : (float)(0.55 * glow));
            }
        // Sorted by bearing for the per-frame arc lookup.
        var order = Enumerable.Range(0, index.Count).ToArray();
        var keys = bearing.ToArray();
        Array.Sort(keys, order);
        ringBearing = keys;
        ringIndex = order.Select(n => index[n]).ToArray();
        ringCore = order.Select(n => core[n]).ToArray();
        ringHalo = order.Select(n => halo[n]).ToArray();
        ringX = ringIndex.Select(i => (short)(i % pixelWidth)).ToArray();
        ringY = ringIndex.Select(i => (short)(i / pixelWidth)).ToArray();
        litArcs.Clear();
    }

    // Depth shadow (black 0.30, sigma 14, 7 DIP down), blue bloom (0.18, sigma 22), the glass with its
    // 6 DIP lip, and the credit with its text shadow.
    private BitmapSource BuildUnder()
    {
        var shadows = Shadows.Value;
        var pixels = new double[pixelWidth * pixelHeight * 4];
        // The Mac material over each theme's usual backdrop (spec 3.2): light over a light app (243) is about
        // 222, dark over the reference dark editor (25, 26, 27) is (33, 34, 36).
        Color fill = look.HighContrast ? look.Window : look.Light ? Color.FromRgb(222, 222, 222) : Color.FromRgb(33, 34, 36);
        bool lip = look.Transparency && !look.HighContrast;
        for (int py = 0; py < pixelHeight; py++)
            for (int px = 0; px < pixelWidth; px++)
            {
                double x = (px + 0.5) / scale, y = (py + 0.5) / scale;
                int at = (py * pixelWidth + px) * 4;
                if (!look.HighContrast)
                {
                    PanelPaint.Over(pixels, at, 0, 0, 0, 0.30 * Sample(shadows.Depth, x, y - 7));
                    PanelPaint.Over(pixels, at, Blue.R / 255.0, Blue.G / 255.0, Blue.B / 255.0, 0.18 * Sample(shadows.Bloom, x, y));
                }
                double depth = PanelGeometry.Depth(x, y);
                double coverage = Math.Clamp(depth * scale, 0, 1);
                double t = Math.Clamp(depth / 6, 0, 1);
                double opacity = lip ? coverage * (0.68 + 0.32 * t * t * (3 - 2 * t)) : coverage;
                PanelPaint.Over(pixels, at, fill.R / 255.0, fill.G / 255.0, fill.B / 255.0, opacity);
            }
        AddCredit(pixels);
        return PanelPaint.ToBitmap(pixels, pixelWidth, pixelHeight, scale);
    }

    private void AddCredit(double[] pixels)
    {
        var typeface = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
        var text = new FormattedText("by Actual Intelligence Labs", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, typeface, 10, LabelBrush(), scale);
        var brand = new SolidColorBrush(look.HighContrast ? look.Text : Blue); brand.Freeze();
        text.SetForegroundBrush(brand, 3, 24);
        var origin = new Point(PanelGeometry.Margin + 282 - text.WidthIncludingTrailingWhitespace, PanelGeometry.Margin + 93 - text.Baseline);
        var visual = new DrawingVisual();
        TextOptions.SetTextRenderingMode(visual, TextRenderingMode.Grayscale);
        using (var dc = visual.RenderOpen()) dc.DrawText(text, origin);
        var target = new RenderTargetBitmap(pixelWidth, pixelHeight, 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        target.Render(visual);
        var glyphs = new byte[pixelWidth * pixelHeight * 4];
        target.CopyPixels(glyphs, pixelWidth * 4, 0);
        if (!look.HighContrast)
        {
            // NSShadow: black at 0.70 (dark) or 0.12 (light), blur radius 1.5 or 0.5 (sigma 0.75 or 0.25), 0.5 down.
            var alpha = new float[pixelWidth * pixelHeight];
            for (int i = 0; i < alpha.Length; i++) alpha[i] = glyphs[i * 4 + 3] / 255f;
            var blurred = PanelPaint.Blur(alpha, pixelWidth, pixelHeight, (look.Light ? 0.25 : 0.75) * scale);
            double strength = look.Light ? 0.12 : 0.70, shift = 0.5 * scale;
            for (int py = 0; py < pixelHeight; py++)
            {
                double source = py - shift;
                int y0 = (int)Math.Floor(source); double f = source - y0;
                for (int px = 0; px < pixelWidth; px++)
                {
                    double a0 = y0 >= 0 && y0 < pixelHeight ? blurred[y0 * pixelWidth + px] : 0;
                    double a1 = y0 + 1 >= 0 && y0 + 1 < pixelHeight ? blurred[(y0 + 1) * pixelWidth + px] : 0;
                    double a = (a0 * (1 - f) + a1 * f) * strength;
                    if (a > 0) PanelPaint.Over(pixels, (py * pixelWidth + px) * 4, 0, 0, 0, a);
                }
            }
        }
        for (int i = 0; i < pixelWidth * pixelHeight; i++)
        {
            double a = glyphs[i * 4 + 3] / 255.0;
            if (a <= 0) continue;
            int at = i * 4;
            pixels[at] = glyphs[i * 4 + 2] / 255.0 + pixels[at] * (1 - a);
            pixels[at + 1] = glyphs[i * 4 + 1] / 255.0 + pixels[at + 1] * (1 - a);
            pixels[at + 2] = glyphs[i * 4] / 255.0 + pixels[at + 2] * (1 - a);
            pixels[at + 3] = a + pixels[at + 3] * (1 - a);
        }
    }

    // Inside light (1 DIP white line at 0.35 with an inward sigma 9 glow at 0.45) under the rim
    // (1.2 DIP stroke, white 0.60 top to 0.18 bottom, clipped to the glass bounding box).
    private BitmapSource BuildOver()
    {
        var pixels = new double[pixelWidth * pixelHeight * 4];
        double w = 1 / scale;
        for (int py = 0; py < pixelHeight; py++)
            for (int px = 0; px < pixelWidth; px++)
            {
                double x = (px + 0.5) / scale, y = (py + 0.5) / scale, d = PanelGeometry.Depth(x, y);
                int at = (py * pixelWidth + px) * 4;
                if (look.HighContrast)
                {
                    PanelPaint.Over(pixels, at, look.Text.R / 255.0, look.Text.G / 255.0, look.Text.B / 255.0, PanelPaint.Band(d, w, 0, 2));
                    continue;
                }
                if (d < -2 || d > 40) continue;
                double line = 0.35 * PanelPaint.Band(d, w, 0, 1);
                double glow = 0.45 * 0.35 * (PanelPaint.Phi((d + 1) / 9) - PanelPaint.Phi((d - 1) / 9)) * Math.Clamp(d * scale + 0.5, 0, 1);
                PanelPaint.Over(pixels, at, 1, 1, 1, glow);
                PanelPaint.Over(pixels, at, 1, 1, 1, line);
                double box = PanelPaint.Band(x, w, PanelGeometry.Margin, PanelGeometry.Margin + PanelGeometry.GlassWidth)
                    * PanelPaint.Band(y, w, PanelGeometry.Margin, PanelGeometry.Margin + PanelGeometry.GlassHeight);
                double rim = PanelPaint.Band(d, w, -0.6, 0.6) * box * RimAlpha((y - PanelGeometry.Margin) / PanelGeometry.GlassHeight);
                PanelPaint.Over(pixels, at, 1, 1, 1, rim);
            }
        return PanelPaint.ToBitmap(pixels, pixelWidth, pixelHeight, scale);
    }

    private static double RimAlpha(double t)
    {
        t = Math.Clamp(t, 0, 1);
        if (t < 0.35) return 0.60 + (0.12 - 0.60) * t / 0.35;
        if (t < 0.75) return 0.12 + (0.03 - 0.12) * (t - 0.35) / 0.40;
        return 0.03 + (0.18 - 0.03) * (t - 0.75) / 0.25;
    }

    // The glass shape blurred on a 1 DIP grid (rows start 8 DIP above the window for the offset shadow).
    private static (float[] Depth, float[] Bloom) BuildShadows()
    {
        var shape = new float[ShadowWidth * ShadowHeight];
        for (int r = 0; r < ShadowHeight; r++)
            for (int c = 0; c < ShadowWidth; c++)
                shape[r * ShadowWidth + c] = (float)Math.Clamp(PanelGeometry.Depth(c + 0.5, r - ShadowTopPad + 0.5) + 0.5, 0, 1);
        return (PanelPaint.Blur(shape, ShadowWidth, ShadowHeight, 14), PanelPaint.Blur(shape, ShadowWidth, ShadowHeight, 22));
    }

    private static double Sample(float[] grid, double x, double y)
    {
        double gx = x - 0.5, gy = y + ShadowTopPad - 0.5;
        int x0 = (int)Math.Floor(gx), y0 = (int)Math.Floor(gy);
        double fx = gx - x0, fy = gy - y0;
        double At(int c, int r) => c < 0 || r < 0 || c >= ShadowWidth || r >= ShadowHeight ? 0 : grid[r * ShadowWidth + c];
        return (At(x0, y0) * (1 - fx) + At(x0 + 1, y0) * fx) * (1 - fy) + (At(x0, y0 + 1) * (1 - fx) + At(x0 + 1, y0 + 1) * fx) * fy;
    }
}

internal static class PanelPaint
{
    /// Standard normal CDF (Abramowitz and Stegun 7.1.26, error under 1.5e-7).
    public static double Phi(double z)
    {
        double x = Math.Abs(z) / Math.Sqrt(2), t = 1 / (1 + 0.3275911 * x);
        double erf = 1 - ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.Exp(-x * x);
        return z >= 0 ? 0.5 * (1 + erf) : 0.5 * (1 - erf);
    }

    // Phi on [-8, 8] every 1/128, linearly interpolated (error under 2e-6), for the per-frame bar glow.
    private const int PhiSteps = 128, PhiRange = 8;
    private static readonly float[] PhiTable = BuildPhiTable();
    private static float[] BuildPhiTable()
    {
        var table = new float[2 * PhiRange * PhiSteps + 2];
        for (int i = 0; i < table.Length; i++) table[i] = (float)Phi(i / (double)PhiSteps - PhiRange);
        return table;
    }
    public static double PhiFast(double z)
    {
        if (!(z > -PhiRange)) return 0;
        if (z >= PhiRange) return 1;
        double u = (z + PhiRange) * PhiSteps;
        int i = (int)u;
        double f = u - i;
        return PhiTable[i] + (PhiTable[i + 1] - PhiTable[i]) * f;
    }

    /// The share of a pixel of width w centered at d that lies inside [lo, hi].
    public static double Band(double d, double w, double lo, double hi) =>
        Math.Max(0, Math.Min(d + w / 2, hi) - Math.Max(d - w / 2, lo)) / w;

    /// Source-over of a straight color into premultiplied RGBA doubles.
    public static void Over(double[] pixels, int at, double r, double g, double b, double a)
    {
        if (!(a > 0)) return;
        a = Math.Min(a, 1);
        pixels[at] = r * a + pixels[at] * (1 - a);
        pixels[at + 1] = g * a + pixels[at + 1] * (1 - a);
        pixels[at + 2] = b * a + pixels[at + 2] * (1 - a);
        pixels[at + 3] = a + pixels[at + 3] * (1 - a);
    }

    public static int Pack(Color color, double alpha)
    {
        if (!(alpha > 0)) return 0;
        return PackPremultiplied(color.R / 255.0 * alpha, color.G / 255.0 * alpha, color.B / 255.0 * alpha, alpha);
    }

    public static int PackPremultiplied(double r, double g, double b, double a)
    {
        static int Byte(double v) => (int)Math.Round(Math.Clamp(v, 0, 1) * 255);
        int alpha = Byte(a);
        return (alpha << 24) | (Math.Min(Byte(r), alpha) << 16) | (Math.Min(Byte(g), alpha) << 8) | Math.Min(Byte(b), alpha);
    }

    public static BitmapSource ToBitmap(double[] pixels, int width, int height, double scale)
    {
        var packed = new int[width * height];
        for (int i = 0; i < packed.Length; i++) packed[i] = PackPremultiplied(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3]);
        var bitmap = BitmapSource.Create(width, height, 96 * scale, 96 * scale, PixelFormats.Pbgra32, null, packed, width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    /// Separable Gaussian blur with zero outside the grid.
    public static float[] Blur(float[] source, int width, int height, double sigma)
    {
        if (!(sigma > 0.05)) return (float[])source.Clone();
        int radius = (int)Math.Ceiling(sigma * 3.5);
        var kernel = new float[2 * radius + 1];
        double sum = 0;
        for (int i = -radius; i <= radius; i++) sum += kernel[i + radius] = (float)Math.Exp(-0.5 * i * i / (sigma * sigma));
        for (int i = 0; i < kernel.Length; i++) kernel[i] = (float)(kernel[i] / sum);
        var temp = new float[source.Length];
        var result = new float[source.Length];
        for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++)
            {
                float acc = 0;
                for (int k = Math.Max(-radius, -x), end = Math.Min(radius, width - 1 - x); k <= end; k++) acc += source[y * width + x + k] * kernel[k + radius];
                temp[y * width + x] = acc;
            }
        for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++)
            {
                float acc = 0;
                for (int k = Math.Max(-radius, -y), end = Math.Min(radius, height - 1 - y); k <= end; k++) acc += temp[(y + k) * width + x] * kernel[k + radius];
                result[y * width + x] = acc;
            }
        return result;
    }
}

/// Sona.exe --panel-preview <dir>: the panel rendered offscreen at 200% over neutral backdrops, driven
/// by the Mac preview's synthetic voice at fixed clock times. No microphone, hotkey, network, settings or tray.
internal static class PanelPreview
{
    public static void Write(string directory)
    {
        Directory.CreateDirectory(directory);
        const double step = 1.0 / 60;
        foreach (var (name, light, processing) in new[] { ("recording-dark", false, false), ("recording-light", true, false), ("processing-dark", false, true), ("processing-light", true, true) })
        {
            var motion = new BarMotion();
            motion.StartRecording();
            var bands = new float[PanelSpectrum.BandCount];
            for (int tick = 1; tick <= 120; tick++) // 2.0 s of recording; bands arrive every 0.1 s.
            {
                if (tick % 6 == 0) { PanelSpectrum.Synthetic(tick * step, bands); motion.SetSpectrum(bands); }
                motion.Advance(step);
            }
            LightPose? pose = null;
            var surface = new PanelSurface();
            surface.Configure(2, PanelLook.Preview(light));
            if (processing)
            {
                motion.StartProcessing();
                for (int tick = 1; tick <= 54; tick++) motion.Advance(step); // 0.9 s into processing.
                pose = LightScript.Generate(new Random(20261006)).At(54 * step);
                surface.LightsVisible = true;
            }
            surface.Update(motion, pose);
            // Same framing as the Mac reference crops: 412x199 DIP with the glass at (56, 39).
            var backdrop = new SolidColorBrush(light ? Color.FromRgb(243, 243, 243) : Color.FromRgb(25, 26, 27));
            backdrop.Freeze();
            var canvas = new System.Windows.Controls.Canvas { Width = 412, Height = 199, Background = backdrop };
            System.Windows.Controls.Canvas.SetLeft(surface, 30); System.Windows.Controls.Canvas.SetTop(surface, 13);
            canvas.Children.Add(surface);
            canvas.Measure(new Size(412, 199)); canvas.Arrange(new Rect(0, 0, 412, 199)); canvas.UpdateLayout();
            var bitmap = new RenderTargetBitmap(824, 398, 192, 192, PixelFormats.Pbgra32);
            bitmap.Render(canvas);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var file = File.Create(Path.Combine(directory, name + ".png"));
            encoder.Save(file);
        }
    }
}
