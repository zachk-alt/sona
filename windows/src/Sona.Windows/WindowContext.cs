using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using Sona.Core;

namespace Sona.Windows;

internal sealed record WindowContext(string Status, FocusTarget? Target = null, WindowImage? Image = null, string AppName = "", string WindowTitle = "", Native.Rect Bounds = default);

// This guard exists only for an explicit invocation. A focus change and return cannot revive it.
internal sealed class WindowInvocation : IDisposable
{
    public nint Window { get; }
    public uint Process { get; }
    private readonly long started;
    private readonly Native.WinEventProc callback;
    private nint hook, focusHook;
    private readonly bool testOwnWindow;
    private bool actionInProgress;
    private uint expectedApp;
    private long expectedStarted, expectedUntil;
    private int changed;
    public event Action? FocusChanged;
    internal uint ExpectedProcess => expectedApp;
    // Unlike Valid, this permits only the one explicitly requested process transition.
    // The hook still latches any other foreground/focus event permanently.
    internal bool ExpectedTransitionValid => hook != 0 && focusHook != 0 && Volatile.Read(ref changed) == 0 && expectedApp != 0 && Environment.TickCount64 < expectedUntil && SameProcess() && SameExpectedProcess();
    public bool Valid => hook != 0 && focusHook != 0 && Volatile.Read(ref changed) == 0 && Native.GetForegroundWindow() == Window && Native.IsWindow(Window) && SameProcess();
    public WindowInvocation(bool testOwnWindow = false)
    {
        this.testOwnWindow = testOwnWindow;
        Window = Native.GetForegroundWindow(); Native.GetWindowThreadProcessId(Window, out var process); Process = process;
        try { using var p = System.Diagnostics.Process.GetProcessById((int)process); started = p.StartTime.ToUniversalTime().Ticks; } catch { changed = 1; }
        if (!testOwnWindow && process == Environment.ProcessId || Window == 0) changed = 1;
        callback = (_, evt, window, _, _, _, _) =>
        {
            Native.GetWindowThreadProcessId(window, out var eventProcess);
            // The requested handoff can produce outgoing and incoming focus events.
            // Only those two pinned processes are permitted, for a bounded transition;
            // physical user input is independently watched by AssistantUserActivity.
            if (expectedApp != 0 && Environment.TickCount64 < expectedUntil && (eventProcess == expectedApp || eventProcess == Process)) return;
            if (actionInProgress && evt == 0x8005 && eventProcess == Process && Native.GetForegroundWindow() == Window) return;
            Interlocked.Exchange(ref changed, 1); FocusChanged?.Invoke();
        };
        hook = Native.SetWinEventHook(3, 3, 0, callback, 0, 0, 0);
        focusHook = Native.SetWinEventHook(0x8005, 0x8005, 0, callback, 0, 0, 0);
    }
    private bool SameProcess()
    {
        Native.GetWindowThreadProcessId(Window, out var pid);
        if (pid != Process) return false;
        try { using var p = System.Diagnostics.Process.GetProcessById((int)pid); return p.StartTime.ToUniversalTime().Ticks == started; } catch { return false; }
    }
    public async Task<WindowContext> CaptureAsync(CancellationToken cancellation, bool screenOnly = false)
    {
        if (!Valid) return new("focus_changed");
        string executable = Environment.ProcessPath ?? throw new InvalidOperationException();
        var args = new List<string>();
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) args.Add(Path.Combine(AppContext.BaseDirectory, "Sona.dll"));
        args.Add(testOwnWindow ? "--assistant-context-test" : "--assistant-context");
        var request = JsonSerializer.Serialize(new { window = Window.ToInt64(), process = Process, owner = Environment.ProcessId, screenOnly });
        // PrintWindow and UIA are synchronous external calls. The parent kills the entire helper at the deadline.
        var response = await BoundedProcess.RunAsync(executable, args, request, TimeSpan.FromSeconds(4), cancellation, maximumOutput: 6 * 1024 * 1024);
        if (!Valid || !response.Success) return new("capture_unavailable");
        try
        {
            using var document = JsonDocument.Parse(response.Output); var root = document.RootElement;
            string? status = root.GetProperty("status").GetString();
            if (status == "selected")
            {
                var focus = Native.FocusAt(Window);
                if (focus.Focus.ToInt64() != root.GetProperty("focus").GetInt64() || focus.Process != Process) return new("focus_changed");
                return new("selected", new(Window, Process, focus.Focus, root.GetProperty("runtimeId").EnumerateArray().Select(v => v.GetInt32()).ToArray()));
            }
            if (status != "screen") return new("capture_unavailable");
            string data = root.GetProperty("dataBase64").GetString()!;
            byte[] pixels = Convert.FromBase64String(data);
            try { if (pixels.Length is 0 or > AssistantProtocol.MaximumImageBytes || !pixels.AsSpan().StartsWith(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })) return new("capture_unavailable"); }
            finally { Array.Clear(pixels); }
            return new("screen", Image: new("image/png", data), AppName: root.GetProperty("appName").GetString() ?? "", WindowTitle: root.GetProperty("windowTitle").GetString() ?? "", Bounds: new() { Left = root.GetProperty("left").GetInt32(), Top = root.GetProperty("top").GetInt32(), Right = root.GetProperty("right").GetInt32(), Bottom = root.GetProperty("bottom").GetInt32() });
        }
        catch { return new("capture_unavailable"); }
    }
    private bool SameExpectedProcess()
    {
        try { using var p = System.Diagnostics.Process.GetProcessById((int)expectedApp); return p.StartTime.ToUniversalTime().Ticks == expectedStarted; }
        catch { return false; }
    }
    public void ExpectApp(uint process)
    {
        if (!Valid) throw new OperationCanceledException();
        using var p = System.Diagnostics.Process.GetProcessById((int)process);
        expectedStarted = p.StartTime.ToUniversalTime().Ticks; expectedUntil = Environment.TickCount64 + 4000; expectedApp = process;
    }
    public void BeginNativeAction() { if (!Valid) throw new OperationCanceledException(); actionInProgress = true; }
    public void EndNativeAction() { actionInProgress = false; }
    public void Dispose() { Interlocked.Exchange(ref changed, 1); if (hook != 0) Native.UnhookWinEvent(hook); if (focusHook != 0) Native.UnhookWinEvent(focusHook); hook = focusHook = 0; }
}

internal static class WindowContextWorker
{
    public static void Run(bool testOwnWindow = false)
    {
        Console.InputEncoding = new UTF8Encoding(false); Console.OutputEncoding = new UTF8Encoding(false);
        try
        {
            string input = Console.In.ReadToEnd(); if (input.Length > 1024) throw new InvalidDataException();
            using var document = JsonDocument.Parse(input); var root = document.RootElement;
            nint window = new(root.GetProperty("window").GetInt64()); uint pid = root.GetProperty("process").GetUInt32(), owner = root.GetProperty("owner").GetUInt32();
            if (testOwnWindow) owner = 0;
            using var targetProcess = Process.GetProcessById((int)pid);
            if (SensitiveProcess(targetProcess.ProcessName)) throw new InvalidDataException();
            if (!Allowed(window, pid, owner, out var rect)) throw new InvalidDataException();
            var element = AutomationElement.FocusedElement;
            // Metadata only. Never inspect a password's value, selection or pixels.
            if (element == null || element.Current.IsPassword || !element.Current.IsEnabled || element.Current.ProcessId != pid) throw new InvalidDataException();
            var elementIdentity = element.GetRuntimeId();
            if (element.TryGetCurrentPattern(TextPattern.Pattern, out var raw))
            {
                var ranges = ((TextPattern)raw).GetSelection();
                if (ranges.Length > 1) throw new InvalidDataException();
                if (ranges.Length == 1 && ranges[0].CompareEndpoints(TextPatternRangeEndpoint.Start, ranges[0], TextPatternRangeEndpoint.End) != 0)
                {
                    bool writable = element.TryGetCurrentPattern(ValuePattern.Pattern, out var editable) ? !((ValuePattern)editable).Current.IsReadOnly : ranges[0].GetAttributeValue(TextPattern.IsReadOnlyAttribute) is bool readOnly && !readOnly;
                    if (writable && !root.GetProperty("screenOnly").GetBoolean())
                    {
                        if (!Allowed(window, pid, owner, out _)) throw new InvalidDataException();
                        var focus = Native.FocusAt(window);
                        Console.Write(JsonSerializer.Serialize(new { status = "selected", focus = focus.Focus.ToInt64(), runtimeId = element.GetRuntimeId() })); return;
                    }
                }
            }
            using var bitmap = new Bitmap(rect.Right - rect.Left, rect.Bottom - rect.Top, PixelFormat.Format32bppRgb);
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.Clear(Color.Magenta); nint dc = graphics.GetHdc();
                try { if (!CaptureNative.PrintWindow(window, dc, 2)) throw new InvalidDataException(); }
                finally { graphics.ReleaseHdc(dc); }
            }
            if (!Allowed(window, pid, owner, out var after) || !rect.Equals(after)) throw new InvalidDataException();
            var currentElement = AutomationElement.FocusedElement;
            if (currentElement == null || currentElement.Current.IsPassword || !currentElement.GetRuntimeId().SequenceEqual(elementIdentity)) throw new InvalidDataException();
            // A failed/black protected rendering must not become a misleading successful screenshot.
            bool rendered = false; int first = bitmap.GetPixel(0, 0).ToArgb();
            for (int y = 0; y < bitmap.Height && !rendered; y += Math.Max(1, bitmap.Height / 64))
                for (int x = 0; x < bitmap.Width; x += Math.Max(1, bitmap.Width / 64))
                    if (bitmap.GetPixel(x, y).ToArgb() != first) { rendered = true; break; }
            if (!rendered) throw new InvalidDataException();
            double scale = Math.Min(1, 2048.0 / Math.Max(bitmap.Width, bitmap.Height));
            using var sized = new Bitmap(Math.Max(1, (int)(bitmap.Width * scale)), Math.Max(1, (int)(bitmap.Height * scale)), PixelFormat.Format24bppRgb);
            using (var graphics = Graphics.FromImage(sized)) { graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic; graphics.DrawImage(bitmap, 0, 0, sized.Width, sized.Height); }
            using var memory = new MemoryStream(); sized.Save(memory, ImageFormat.Png);
            if (memory.Length > AssistantProtocol.MaximumImageBytes || !Allowed(window, pid, owner, out _)) throw new InvalidDataException();
            var title = new StringBuilder(512); CaptureNative.GetWindowText(window, title, title.Capacity);
            using var app = Process.GetProcessById((int)pid);
            Console.Write(JsonSerializer.Serialize(new { status = "screen", dataBase64 = Convert.ToBase64String(memory.GetBuffer(), 0, (int)memory.Length), appName = app.ProcessName, windowTitle = title.ToString(), left = rect.Left, top = rect.Top, right = rect.Right, bottom = rect.Bottom }));
            Array.Clear(memory.GetBuffer());
        }
        catch { Console.Write("{\"status\":\"unavailable\"}"); }
    }
    internal static bool SensitiveProcess(string name) => new[] { "consent", "CredentialUIBroker", "LogonUI", "winlogon", "LockApp", "Microsoft.AAD.BrokerPlugin", "AccountsControlHost" }.Contains(name, StringComparer.OrdinalIgnoreCase);
    private static bool Allowed(nint window, uint pid, uint owner, out Native.Rect rect)
    {
        bool rectangle = CaptureNative.GetWindowRect(window, out rect);
        Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out var currentPid);
        bool affinityKnown = CaptureNative.GetWindowDisplayAffinity(window, out var affinity);
        bool cloakKnown = CaptureNative.DwmGetWindowAttribute(window, 14, out var cloaked, 4) == 0;
        return rectangle && cloakKnown && WindowCapturePolicy.Allowed(window.ToInt64(), pid, Native.GetForegroundWindow().ToInt64(), currentPid, owner, Native.IsWindow(window), CaptureNative.IsIconic(window), cloaked != 0, affinityKnown, affinity, rect.Right - rect.Left, rect.Bottom - rect.Top);
    }
}

internal static class CaptureNative
{
    [DllImport("user32.dll")] public static extern bool PrintWindow(nint window, nint dc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(nint window, out Native.Rect rect);
    [DllImport("user32.dll")] public static extern bool IsIconic(nint window);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool GetWindowDisplayAffinity(nint window, out uint affinity);
    [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(nint window, uint affinity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(nint window, StringBuilder title, int count);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(nint window, int attribute, out int value, int size);
}
