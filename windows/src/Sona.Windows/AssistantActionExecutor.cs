using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Automation;
using Sona.Core;

namespace Sona.Windows;

internal sealed record ActionOutcome(bool Success, string Receipt, nint NewWindow = 0, bool Stop = false);
internal sealed record AppTarget(string Id, string Label, nint Window, uint Process, long Started, string? Executable = null);
internal sealed class AssistantActionExecutor : IDisposable
{
    private readonly Dictionary<string, AppTarget> apps = new();
    private AssistantCursor? cursor;
    public void Dispose() { cursor?.Dispose(); cursor = null; }
    public AssistantApp[] Catalog()
    {
        apps.Clear();
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    if (process.Id == Environment.ProcessId || WindowContextWorker.SensitiveProcess(process.ProcessName) || process.MainWindowHandle == 0 || apps.Count >= 60) continue;
                    string id = "running:" + process.Id; apps[id] = new(id, process.ProcessName, process.MainWindowHandle, (uint)process.Id, process.StartTime.ToUniversalTime().Ticks);
                }
                catch { }
            }
        }
        foreach (var item in new[] { ("notepad", "Notepad", "notepad.exe"), ("calculator", "Calculator", "calc.exe"), ("paint", "Paint", "mspaint.exe") })
        {
            string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), item.Item3);
            if (File.Exists(path)) apps["installed:" + item.Item1] = new("installed:" + item.Item1, item.Item2, 0, 0, 0, path);
        }
        return apps.Values.Select(a => new AssistantApp(a.Id, a.Label)).ToArray();
    }
    private static bool Ready(WindowInvocation invocation, WindowContext context)
        => invocation.Valid && !Native.AnyModifierHeld() && CaptureNative.GetWindowRect(invocation.Window, out var rect) && rect.Equals(context.Bounds) && CaptureNative.GetWindowDisplayAffinity(invocation.Window, out var affinity) && affinity == 0;
    public async Task<ActionOutcome> ExecuteAsync(WindowInvocation invocation, WindowContext context, AssistantAction action, Func<string, CancellationToken, Task<bool>> approve, CancellationToken cancellation)
    {
        try
        {
            var outcome = await ExecuteOnceAsync(invocation, context, action, approve, cancellation);
            if (!outcome.Success) cursor?.Hide();
            return outcome;
        }
        catch { cursor?.Hide(); throw; }
    }
    private async Task<ActionOutcome> ExecuteOnceAsync(WindowInvocation invocation, WindowContext context, AssistantAction action, Func<string, CancellationToken, Task<bool>> approve, CancellationToken cancellation)
    {
        // Native/UIA point lookup must see the destination alone, even on a platform
        // where a mouse-transparent overlay participates in accessibility hit testing.
        cursor?.Hide();
        if (action.Type == "wait" && !AssistantWait.ValidDuration(action.Milliseconds)) return new(false, "Wait refused: duration is outside its bound.");
        if (!Ready(invocation, context)) return new(false, "Action not dispatched: target changed or a modifier is held.");
        JsonElement check = default;
        if (action.Type is "click" or "key" or "scroll" or "type")
        {
            check = await WorkerAsync(invocation, context, action, false, null, cancellation);
            if (check.ValueKind != JsonValueKind.Object || !check.TryGetProperty("status", out var value) || value.GetString() != "ready") return new(false, "Action not dispatched: no verifiable non-protected UIA control.");
        }
        string? label = check.ValueKind == JsonValueKind.Object && check.TryGetProperty("label", out var name) ? name.GetString() : null;
        bool approved = false;
        if (AssistantActionPolicy.Confirm(action, label))
        {
            string description = action.Type == "wait" ? "Wait briefly before checking this window again?"
                : "Approve " + action.Type + (action.Type == "key" ? " “" + action.Key + "”" : label == null ? "" : " on “" + label + "”") + "? This may send, publish or change data.";
            if (!await approve(description, cancellation)) return new(false, "Action cancelled at the confirmation panel.");
            approved = true;
        }
        if (!Ready(invocation, context) || cancellation.IsCancellationRequested) return new(false, "Action not dispatched: target changed.");
        if (action.Type == "wait")
        {
            // Do not suppress target/focus observation or enter the UIA/input path.
            bool current = await AssistantWait.RunAsync(action.Milliseconds, () => Ready(invocation, context), cancellation);
            return current ? new(true, "Waited briefly without sending input. Inspect the fresh image before continuing.")
                : new(false, "Wait stopped: the foreground target changed.");
        }
        if (action.Type == "open_app") return await OpenAppAsync(invocation, action.AppId!, cancellation);
        if (action.Type == "open_url") return await OpenUrlAsync(invocation, context, action.Url!, cancellation);
        invocation.BeginNativeAction();
        try
        {
            if (action.Type == "type")
            {
                var target = await TextInsertion.CaptureAsync();
                if (target == null || !target.RuntimeId.SequenceEqual(check.GetProperty("runtimeId").EnumerateArray().Select(v => v.GetInt32())) || !Ready(invocation, context)) return new(false, "Typing refused: the editable field could not be verified.");
                using var selection = await UiaSession.StartAsync(target, selection: true);
                if (selection == null || !await selection.ValidateAsync()) return new(false, "Typing refused: the selection is unavailable.");
                async Task<bool> ValidateType()
                {
                    if (!Ready(invocation, context) || !await selection.ValidateAsync()) return false;
                    var verified = await WorkerAsync(invocation, context, action, false, null, cancellation);
                    return verified.ValueKind == JsonValueKind.Object && verified.GetProperty("status").GetString() == "ready" && verified.GetProperty("label").GetString() == label && verified.GetProperty("runtimeId").EnumerateArray().Select(v => v.GetInt32()).SequenceEqual(target.RuntimeId);
                }
                bool pasted = await TextInsertion.PasteAsync(target, action.Text!, ValidateType, () => invocation.Valid && !cancellation.IsCancellationRequested, new OneShotCommit());
                return new(pasted, pasted ? "Typed the requested text once in the verified field." : "Typing was blocked or dispatch was uncertain. No retry was made.");
            }
            if (action.Type == "click")
            {
                cursor ??= new AssistantCursor();
                await cursor.MoveAsync(context.Bounds, action.X, action.Y, cancellation);
                cancellation.ThrowIfCancellationRequested();
                if (!Ready(invocation, context)) { cursor.Hide(); return new(false, "Action not dispatched: target changed while the Sona cursor moved."); }
                cursor.Hide();
            }
            var result = await WorkerAsync(invocation, context, action, true, check.GetProperty("runtimeId").EnumerateArray().Select(v => v.GetInt32()).ToArray(), cancellation, approved, label);
            bool ok = result.ValueKind == JsonValueKind.Object && result.TryGetProperty("status", out var status) && status.GetString() == "dispatched";
            if (ok && action.Type == "click") await cursor!.PulseAsync(cancellation);
            return new(ok, ok ? "Dispatched one verified " + action.Type + " action. Inspect the fresh image to determine its effect." : "Action dispatch failed or was uncertain. No retry was made.");
        }
        finally { await Task.Delay(150, CancellationToken.None); invocation.EndNativeAction(); }
    }
    private async Task<ActionOutcome> OpenAppAsync(WindowInvocation invocation, string id, CancellationToken cancellation)
    {
        if (!apps.TryGetValue(id, out var app)) return new(false, "Unknown app ID was refused.");
        try
        {
            nint window = app.Window;
            if (window != 0)
            {
                using var p = Process.GetProcessById((int)app.Process);
                Native.GetWindowThreadProcessId(window, out var pid);
                if (pid != app.Process || p.StartTime.ToUniversalTime().Ticks != app.Started) return new(false, "The selected app changed.");
                invocation.ExpectApp(app.Process);
                ActionNative.SetForegroundWindow(window);
            }
            else
            {
                using var p = Process.Start(new ProcessStartInfo(app.Executable!) { UseShellExecute = false });
                if (p == null) return new(false, "App launch failed.");
                invocation.ExpectApp((uint)p.Id);
                for (int i = 0; i < 15 && window == 0; i++) { await Task.Delay(100, cancellation); p.Refresh(); window = p.MainWindowHandle; }
                if (window != 0) ActionNative.SetForegroundWindow(window);
            }
            nint settled = window == 0 ? 0 : await SettleAsync(invocation, window, cancellation);
            return settled != 0 ? new(true, "Opened the selected catalog app and verified its foreground window.", settled) : new(true, "Requested the selected app. Its foreground identity could not be verified, so continuation stopped.", Stop: true);
        }
        catch { return new(false, "The app could not be opened safely."); }
    }
    private async Task<ActionOutcome> OpenUrlAsync(WindowInvocation invocation, WindowContext context, string url, CancellationToken cancellation)
    {
        string address = new Uri(url).AbsoluteUri;
        if (!BrowserTargetPolicy.IsBrowser(context.AppName))
        {
            try { Process.Start(new ProcessStartInfo(address) { UseShellExecute = true }); return new(true, "Opened the requested HTTP(S) URL in the system browser. Start a new Assistant question from its window.", Stop: true); }
            catch { return new(false, "The URL could not be opened."); }
        }
        try
        {
            // Freeze to the browser already being discussed. Do not redirect a Chrome,
            // Edge, Firefox or Brave request to the user's unrelated default browser.
            using var browser = Process.GetProcessById((int)invocation.Process);
            string? executable = browser.MainModule?.FileName;
            if (!invocation.Valid || executable == null || !BrowserTargetPolicy.ExecutableMatches(browser.ProcessName, executable)
                || !browser.ProcessName.Equals(context.AppName, StringComparison.OrdinalIgnoreCase) || !File.Exists(executable))
                return new(false, "The current browser executable could not be verified. No other browser was opened.");
            invocation.ExpectApp(invocation.Process);
            using var started = Process.Start(new ProcessStartInfo(executable) { UseShellExecute = false, ArgumentList = { address } });
            nint settled = await SettleAsync(invocation, 0, cancellation);
            return settled != 0 ? new(true, "Opened the requested URL in the current " + context.AppName + " browser and verified its foreground window.", settled)
                : new(true, "Requested the URL in the current browser. Its new foreground view did not settle, so continuation stopped.", Stop: true);
        }
        catch (OperationCanceledException) { throw; }
        catch { return new(false, "The URL could not be opened in the current browser. No other browser was opened."); }
    }
    private static async Task<nint> SettleAsync(WindowInvocation invocation, nint exactWindow, CancellationToken cancellation)
    {
        var settle = new WindowSettle(Environment.TickCount64);
        while (!settle.Expired(Environment.TickCount64))
        {
            cancellation.ThrowIfCancellationRequested();
            if (!invocation.ExpectedTransitionValid) return 0;
            nint foreground = Native.GetForegroundWindow(); Native.GetWindowThreadProcessId(foreground, out var process);
            if (process == invocation.ExpectedProcess && (exactWindow == 0 || foreground == exactWindow)
                && CaptureNative.GetWindowRect(foreground, out var bounds)
                && CaptureNative.GetWindowDisplayAffinity(foreground, out var affinity) && affinity == 0)
            {
                var focus = Native.FocusAt(foreground);
                if (focus.Process == process)
                {
                    if (settle.Observe(Environment.TickCount64, foreground.ToInt64(), process, focus.Focus.ToInt64(), bounds.Left, bounds.Top, bounds.Right, bounds.Bottom)) return foreground;
                }
                else settle.Observe(Environment.TickCount64, 0, 0, 0, 0, 0, 0, 0);
            }
            else settle.Observe(Environment.TickCount64, 0, 0, 0, 0, 0, 0, 0);
            await Task.Delay(75, cancellation);
        }
        return 0;
    }
    private static async Task<JsonElement> WorkerAsync(WindowInvocation invocation, WindowContext context, AssistantAction action, bool execute, int[]? identity, CancellationToken cancellation, bool approved = false, string? expectedLabel = null)
    {
        string executable = Environment.ProcessPath!; var args = new List<string>();
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) args.Add(Path.Combine(AppContext.BaseDirectory, "Sona.dll"));
        args.Add("--assistant-action");
        string request = JsonSerializer.Serialize(new { window = invocation.Window.ToInt64(), process = invocation.Process, left = context.Bounds.Left, top = context.Bounds.Top, right = context.Bounds.Right, bottom = context.Bounds.Bottom, action, execute, identity, approved, expectedLabel }, SettingsStore.JsonOptions);
        var result = await BoundedProcess.RunAsync(executable, args, request, TimeSpan.FromSeconds(3), cancellation);
        try { if (result.Success) { using var json = JsonDocument.Parse(result.Output); return json.RootElement.Clone(); } } catch { }
        return default;
    }
}

internal static class AssistantActionWorker
{
    public static void Run()
    {
        Console.InputEncoding = new System.Text.UTF8Encoding(false); Console.OutputEncoding = new System.Text.UTF8Encoding(false);
        try
        {
            string input = Console.In.ReadToEnd(); if (input.Length > 131072) throw new InvalidDataException();
            using var document = JsonDocument.Parse(input); var root = document.RootElement;
            nint window = new(root.GetProperty("window").GetInt64()); uint pid = root.GetProperty("process").GetUInt32();
            var bounds = new Native.Rect { Left = root.GetProperty("left").GetInt32(), Top = root.GetProperty("top").GetInt32(), Right = root.GetProperty("right").GetInt32(), Bottom = root.GetProperty("bottom").GetInt32() };
            var action = AssistantActionPolicy.Parse(root.GetProperty("action")); bool execute = root.GetProperty("execute").GetBoolean();
            bool Guard()
            {
                Native.GetWindowThreadProcessId(window, out var current);
                return Native.GetForegroundWindow() == window && current == pid && !Native.AnyModifierHeld() && !Native.MenuActive() && CaptureNative.GetWindowRect(window, out var rect) && rect.Equals(bounds) && CaptureNative.GetWindowDisplayAffinity(window, out var affinity) && affinity == 0;
            }
            if (!Guard()) throw new InvalidDataException();
            var focused = AutomationElement.FocusedElement;
            if (focused == null || focused.Current.IsPassword || focused.Current.ProcessId != pid) throw new InvalidDataException();
            AutomationElement? element = focused;
            if (action.Type == "click")
            {
                var point = new ActionNative.Point { X = bounds.Left + (int)(action.X * (bounds.Right - bounds.Left - 1)), Y = bounds.Top + (int)(action.Y * (bounds.Bottom - bounds.Top - 1)) };
                if (ActionNative.GetAncestor(ActionNative.WindowFromPoint(point), 2) != window) throw new InvalidDataException();
                element = AutomationElement.FromPoint(new System.Windows.Point(point.X, point.Y));
                if (element == null || !element.Current.BoundingRectangle.Contains(new System.Windows.Point(point.X, point.Y))) throw new InvalidDataException();
            }
            if (element.Current.ProcessId != pid || element.Current.IsPassword || !element.Current.IsEnabled || element.Current.IsOffscreen) throw new InvalidDataException();
            using var targetProcess = Process.GetProcessById((int)pid);
            var windowTitle = new System.Text.StringBuilder(512); CaptureNative.GetWindowText(window, windowTitle, windowTitle.Capacity);
            if (WindowContextWorker.SensitiveProcess(targetProcess.ProcessName) || AssistantActionPolicy.Terminal(targetProcess.ProcessName, windowTitle + " " + element.Current.Name + " " + element.Current.HelpText)) throw new InvalidDataException();
            bool editable = element.TryGetCurrentPattern(ValuePattern.Pattern, out var value) && !((ValuePattern)value).Current.IsReadOnly;
            if (action.Type == "type" || action.Type == "key" && action.Key is "backspace" or "delete") if (!editable) throw new InvalidDataException();
            bool canClick = action.Type != "click" || element.TryGetCurrentPattern(InvokePattern.Pattern, out _) || element.TryGetCurrentPattern(TogglePattern.Pattern, out _) || editable;
            if (!canClick) throw new InvalidDataException();
            string label = element.Current.Name ?? ""; if (label.Length > 256) label = label[..256];
            if (!execute) { Console.Write(JsonSerializer.Serialize(new { status = "ready", label, runtimeId = element.GetRuntimeId() })); return; }
            var identity = root.GetProperty("identity").EnumerateArray().Select(v => v.GetInt32()).ToArray();
            if (!element.GetRuntimeId().SequenceEqual(identity) || label != root.GetProperty("expectedLabel").GetString() || AssistantActionPolicy.Confirm(action, label) && !root.GetProperty("approved").GetBoolean() || !Guard()) throw new InvalidDataException();
            if (action.Type == "click")
            {
                if (element.TryGetCurrentPattern(InvokePattern.Pattern, out var invoke)) ((InvokePattern)invoke).Invoke();
                else if (element.TryGetCurrentPattern(TogglePattern.Pattern, out var toggle)) ((TogglePattern)toggle).Toggle();
                else if (editable) element.SetFocus();
                else throw new InvalidDataException();
            }
            else if (action.Type == "key")
            {
                ushort key = action.Key switch { "enter" or "shift+enter" => 0x0D, "tab" => 9, "escape" => 0x1B, "backspace" => 8, "delete" => 0x2E, "left" => 0x25, "right" => 0x27, "up" => 0x26, "down" => 0x28, "cmd+a" => 0x41, "cmd+z" => 0x5A, _ => throw new InvalidDataException() };
                ushort modifier = action.Key!.StartsWith("cmd+") ? (ushort)0x11 : action.Key == "shift+enter" ? (ushort)0x10 : (ushort)0;
                Native.Input Key(ushort value, bool up) => new() { Type = 1, Data = new() { Keyboard = new() { Key = value, Flags = up ? 2u : 0u } } };
                Native.Input[] keys = modifier == 0 ? [Key(key, false), Key(key, true)] : [Key(modifier, false), Key(key, false), Key(key, true), Key(modifier, true)];
                uint sent = Native.SendInput((uint)keys.Length, keys, Marshal.SizeOf<Native.Input>());
                if (sent != keys.Length) { if (modifier != 0) Native.SendInput(1, [Key(modifier, true)], Marshal.SizeOf<Native.Input>()); throw new InvalidDataException(); }
            }
            else if (action.Type == "scroll")
            {
                if (!element.TryGetCurrentPattern(ScrollPattern.Pattern, out var scroll)) throw new InvalidDataException();
                for (int i = 0; i < action.Amount; i++) { if (!Guard()) throw new InvalidDataException(); ((ScrollPattern)scroll).Scroll(ScrollAmount.NoAmount, action.Direction == "up" ? ScrollAmount.SmallDecrement : ScrollAmount.SmallIncrement); }
            }
            else throw new InvalidDataException();
            Console.Write("{\"status\":\"dispatched\"}");
        }
        catch { Console.Write("{\"status\":\"unavailable\"}"); }
    }
}

internal static class ActionNative
{
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [DllImport("user32.dll")] public static extern nint WindowFromPoint(Point point);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] public static extern nint GetAncestor(nint window, uint flag);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(nint window);
}
