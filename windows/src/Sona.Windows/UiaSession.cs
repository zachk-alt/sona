using System.Diagnostics;
using System.Text.Json;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using Sona.Core;

namespace Sona.Windows;

// Same signed executable, no installation or new dependency. This process owns all live
// selection ranges. Killing it ends observation even when an external UIA call is stuck.
internal sealed class UiaSession : IDisposable
{
    private readonly Process process;
    private readonly SemaphoreSlim gate = new(1);
    private readonly CancellationTokenSource lifetime = new();
    private bool disposed;
    internal static int StartedProcesses;
    public static Task<UiaSession?> PrepareCorrectionAsync(bool enabled, FocusTarget target) => enabled ? StartAsync(target, selection: false) : Task.FromResult<UiaSession?>(null);
    internal bool IsRunning { get { try { return !disposed && !process.HasExited; } catch { return false; } } }
    public string Selection { get; private set; } = "";
    public string Status { get; private set; } = "unavailable";
    private UiaSession(Process process) { this.process = process; }
    public static async Task<UiaSession?> StartAsync(FocusTarget target, bool selection, bool testSynthetic = false)
    {
        string executable = Environment.ProcessPath ?? throw new InvalidOperationException("The executable path is unavailable.");
        var start = new ProcessStartInfo(executable) { StandardInputEncoding = new System.Text.UTF8Encoding(false), StandardOutputEncoding = new System.Text.UTF8Encoding(false), UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) start.ArgumentList.Add(Path.Combine(AppContext.BaseDirectory, "Sona.dll"));
        start.ArgumentList.Add(testSynthetic ? "--uia-session-test" : "--uia-session");
        var p = new Process { StartInfo = start };
        UiaSession? session = null;
        try
        {
            p.Start(); Interlocked.Increment(ref StartedProcesses); session = new(p);
            // A command session is also bounded if the application fails to finish it.
            session.lifetime.CancelAfter(TimeSpan.FromMinutes(6));
            session.lifetime.Token.Register(session.Kill);
            var reply = await session.CallAsync(new { command = "capture", window = target.Window.ToInt64(), process = target.Process, focus = target.Focus.ToInt64(), runtimeId = target.RuntimeId, selection });
            session.Status = reply.GetProperty("status").GetString()!;
            session.Selection = reply.TryGetProperty("text", out var text) ? text.GetString() ?? "" : "";
            if (session.Status is not ("selected" or "empty" or "anchor")) { session.Dispose(); return null; }
            return session;
        }
        catch { session?.Dispose(); if (session == null) { try { if (!p.HasExited) p.Kill(true); } catch { } p.Dispose(); } return null; }
    }
    public async Task<int> ReadCountAsync() => (await CallAsync(new { command = "stats" })).GetProperty("reads").GetInt32();
    public async Task<bool> ValidateAsync()
    {
        try { return (await CallAsync(new { command = "validate" })).GetProperty("status").GetString() == "valid"; }
        catch { return false; }
    }
    public async Task<bool> ArmAsync(string text)
    {
        try
        {
            bool ok = (await CallAsync(new { command = "arm", text })).GetProperty("status").GetString() == "armed";
            if (ok) lifetime.CancelAfter(TimeSpan.FromSeconds(15));
            return ok;
        }
        catch { return false; }
    }
    public async Task<(bool Active, WordCorrection? Candidate)> ObserveAsync()
    {
        try
        {
            var r = await CallAsync(new { command = "observe" });
            string? status = r.GetProperty("status").GetString();
            return (status is "active" or "candidate", status == "candidate" ? new(r.GetProperty("original").GetString()!, r.GetProperty("replacement").GetString()!) : null);
        }
        catch { return (false, null); }
    }
    private async Task<JsonElement> CallAsync(object request)
    {
        await gate.WaitAsync(lifetime.Token);
        try
        {
            if (disposed) throw new OperationCanceledException();
            using var call = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            call.CancelAfter(TimeSpan.FromSeconds(2));
            await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(request).AsMemory(), call.Token);
            await process.StandardInput.FlushAsync(call.Token);
            string? line = await process.StandardOutput.ReadLineAsync(call.Token);
            if (line == null || line.Length > 70000) throw new InvalidDataException();
            using var document = JsonDocument.Parse(line); return document.RootElement.Clone();
        }
        catch { Kill(); throw; }
        finally { gate.Release(); }
    }
    private void Kill() { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { } }
    public void Dispose()
    {
        if (disposed) return; disposed = true; lifetime.Cancel(); Kill();
        process.Dispose(); lifetime.Dispose(); Selection = "";
    }
}

internal static class UiaWorker
{
    public static void Run(bool testSynthetic = false)
    {
        Console.InputEncoding = new System.Text.UTF8Encoding(false); Console.OutputEncoding = new System.Text.UTF8Encoding(false);
        AutomationElement? element = null;
        TextPattern? pattern = null;
        TextPatternRange? selected = null, editStart = null, editLimit = null;
        var words = new List<TextPatternRange>();
        string original = "";
        long window = 0, focus = 0, expires = 0, lastKey = 0;
        uint process = 0; int[] identity = [];
        bool commandSelection = false, armed = false, awaitingPaste = false, stopped = false;
        int changed = 0, dirty = 0, budget = 0, selectionBudget = 0, pasteKeys = 0, pasteChanges = 0, contentReads = 0;
        nint keyboard = 0, mouse = 0, focusHook = 0, foregroundHook = 0;
        Native.WinEventProc focusEvent = (_, _, _, _, _, _, _) => stopped = true;
        bool Matches()
        {
            nint current = Native.GetForegroundWindow(); var native = Native.FocusAt(current);
            if (current.ToInt64() != window || native.Process != process || native.Focus.ToInt64() != focus || Native.MenuActive()) return false;
            var currentElement = AutomationElement.FocusedElement;
            return currentElement != null && !currentElement.Current.IsPassword && currentElement.Current.IsEnabled && currentElement.GetRuntimeId().SequenceEqual(identity);
        }
        string Read(TextPatternRange range, int limit)
        {
            contentReads++;
            string value = range.GetText(limit + 1);
            if (value.Length > limit) throw new InvalidDataException("range_limit");
            return value;
        }
        AutomationEventHandler handler = (_, _) =>
        {
            if (commandSelection) Interlocked.Exchange(ref changed, 1);
            else if (awaitingPaste) { if (pasteKeys < 2 || Interlocked.Increment(ref pasteChanges) != 1) stopped = true; }
            else if (armed && Interlocked.Exchange(ref budget, 0) != 1) stopped = true;
            Interlocked.Exchange(ref dirty, 1);
        };
        AutomationEventHandler selectionHandler = (_, _) =>
        {
            if (armed && editStart != null && (Environment.TickCount64 - lastKey > 150 || Interlocked.Exchange(ref selectionBudget, 0) != 1)) stopped = true;
        };
        Native.HookProc mouseHook = (code, message, data) =>
        {
            if (code >= 0 && armed && editStart != null && message.ToInt32() is 0x201 or 0x204 or 0x207 or 0x20B or 0x20A or 0x20E) stopped = true;
            return Native.CallNextHookEx(mouse, code, message, data);
        };
        Native.HookProc keyHook = (code, message, data) =>
        {
            try
            {
                if (code < 0 || stopped) return Native.CallNextHookEx(keyboard, code, message, data);
                bool down = message.ToInt32() is Native.WmKeydown or Native.WmSyskeydown;
                bool up = message.ToInt32() is Native.WmKeyup or Native.WmSyskeyup;
                if (!down && !up) return Native.CallNextHookEx(keyboard, code, message, data);
                int key = System.Runtime.InteropServices.Marshal.ReadInt32(data);
                bool synthetic = (System.Runtime.InteropServices.Marshal.ReadInt32(data, 8) & 0x10) != 0;
                if (awaitingPaste)
                {
                    // The only allowed intervening input is the app's complete injected Ctrl+V.
                    int normalized = key is 0xA2 or 0xA3 ? 0x11 : key;
                    bool expected = synthetic && (pasteKeys switch { 0 => normalized == 0x11 && down, 1 => normalized == 0x56 && down, 2 => normalized == 0x56 && up, 3 => normalized == 0x11 && up, _ => false });
                    if (expected) pasteKeys++; else stopped = true;
                    return Native.CallNextHookEx(keyboard, code, message, data);
                }
                if (!armed || !down) return Native.CallNextHookEx(keyboard, code, message, data);
                if (key is 0xA0 or 0xA1) return Native.CallNextHookEx(keyboard, code, message, data);
                if (synthetic && !testSynthetic || key is < 0x41 or > 0x5A || Native.Held(0x11) || Native.Held(0x12) || Native.Held(0x5B) || Native.Held(0x5C) || !Matches()) { stopped = true; return Native.CallNextHookEx(keyboard, code, message, data); }
                // Metadata only, before the physical edit is forwarded. No keystroke text is read.
                var ranges = pattern!.GetSelection();
                if (ranges.Length != 1) { stopped = true; return Native.CallNextHookEx(keyboard, code, message, data); }
                if (editStart == null)
                {
                    var matched = words.FirstOrDefault(w => w.Compare(ranges[0]));
                    if (matched == null) { stopped = true; return Native.CallNextHookEx(keyboard, code, message, data); }
                    editStart = matched.Clone(); editStart.MoveEndpointByRange(TextPatternRangeEndpoint.End, matched, TextPatternRangeEndpoint.Start);
                    editLimit = matched.Clone(); editLimit.MoveEndpointByRange(TextPatternRangeEndpoint.Start, matched, TextPatternRangeEndpoint.End);
                }
                else if (ranges[0].CompareEndpoints(TextPatternRangeEndpoint.Start, ranges[0], TextPatternRangeEndpoint.End) != 0 || ranges[0].CompareEndpoints(TextPatternRangeEndpoint.Start, editStart, TextPatternRangeEndpoint.Start) < 0 || ranges[0].CompareEndpoints(TextPatternRangeEndpoint.End, editLimit!, TextPatternRangeEndpoint.End) > 0)
                { stopped = true; return Native.CallNextHookEx(keyboard, code, message, data); }
                lastKey = Environment.TickCount64; Interlocked.Exchange(ref selectionBudget, 1); Interlocked.Exchange(ref budget, 1);
            }
            catch { stopped = true; }
            return Native.CallNextHookEx(keyboard, code, message, data);
        };
        object Handle(JsonElement request)
        {
            string? action = request.GetProperty("command").GetString();
            if (action == "stats") return new { reads = contentReads };
            if (action == "capture")
            {
                window = request.GetProperty("window").GetInt64(); process = request.GetProperty("process").GetUInt32(); focus = request.GetProperty("focus").GetInt64();
                identity = request.GetProperty("runtimeId").EnumerateArray().Select(v => v.GetInt32()).ToArray(); commandSelection = request.GetProperty("selection").GetBoolean();
                if (!Matches()) return new { status = "unavailable" };
                element = AutomationElement.FocusedElement;
                if (element == null || !element.TryGetCurrentPattern(TextPattern.Pattern, out var p)) return new { status = "unsupported" };
                pattern = (TextPattern)p; var ranges = pattern.GetSelection();
                if (ranges.Length != 1) return new { status = "unsupported" };
                selected = ranges[0].Clone();
                bool writable = element.TryGetCurrentPattern(ValuePattern.Pattern, out var editable) ? !((ValuePattern)editable).Current.IsReadOnly : selected.GetAttributeValue(TextPattern.IsReadOnlyAttribute) is bool ro && !ro;
                if (!writable) return new { status = "protected_or_unknown" };
                bool empty = selected.CompareEndpoints(TextPatternRangeEndpoint.Start, selected, TextPatternRangeEndpoint.End) == 0;
                if (commandSelection)
                {
                    original = Read(selected, 32768);
                    if (!empty && original.Length == 0) return new { status = "unsupported" };
                    Automation.AddAutomationEventHandler(TextPattern.TextSelectionChangedEvent, element, TreeScope.Element, handler);
                    Automation.AddAutomationEventHandler(TextPattern.TextChangedEvent, element, TreeScope.Element, handler);
                    return new { status = empty ? "empty" : "selected", text = original };
                }
                // Initial capability is deliberately empty-field-only. No surrounding text reads.
                var document = pattern.DocumentRange;
                if (!empty || document.CompareEndpoints(TextPatternRangeEndpoint.Start, document, TextPatternRangeEndpoint.End) != 0) return new { status = "unsupported" };
                keyboard = Native.SetWindowsHookEx(Native.WhKeyboardLl, keyHook, Native.GetModuleHandle(null), 0);
                mouse = Native.SetWindowsHookEx(Native.WhMouseLl, mouseHook, Native.GetModuleHandle(null), 0);
                focusHook = Native.SetWinEventHook(0x8005, 0x8005, 0, focusEvent, 0, 0, 0);
                foregroundHook = Native.SetWinEventHook(3, 3, 0, focusEvent, 0, 0, 0);
                if (keyboard == 0 || mouse == 0 || focusHook == 0 || foregroundHook == 0) return new { status = "unsupported" };
                awaitingPaste = true;
                Automation.AddAutomationEventHandler(TextPattern.TextChangedEvent, element, TreeScope.Element, handler);
                return new { status = "anchor" };
            }
            if (stopped || !Matches() || pattern == null || selected == null) return new { status = "stopped" };
            if (action == "validate")
            {
                if (!commandSelection || Volatile.Read(ref changed) != 0) return new { status = "invalid" };
                var ranges = pattern.GetSelection();
                return new { status = ranges.Length == 1 && ranges[0].Compare(selected) && Read(ranges[0], 32768) == original ? "valid" : "invalid" };
            }
            if (action == "arm")
            {
                if (commandSelection || pasteKeys != 4 || Volatile.Read(ref pasteChanges) != 1 || !awaitingPaste) return new { status = "stopped" };
                original = request.GetProperty("text").GetString()!;
                // ASCII single-line text gives an exact UIA Character offset mapping. Other text skips learning.
                if (original.Length is 0 or > 4096 || original.Any(c => c < 32 || c > 126)) return new { status = "stopped" };
                var document = pattern.DocumentRange; var end = document.Clone();
                end.MoveEndpointByRange(TextPatternRangeEndpoint.End, end, TextPatternRangeEndpoint.Start);
                if (end.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, original.Length) != original.Length || end.CompareEndpoints(TextPatternRangeEndpoint.End, document, TextPatternRangeEndpoint.End) != 0) return new { status = "stopped" };
                if (Volatile.Read(ref stopped) || Volatile.Read(ref pasteChanges) != 1 || Read(document, original.Length) != original) return new { status = "stopped" };
                selected = document.Clone();
                foreach (System.Text.RegularExpressions.Match word in System.Text.RegularExpressions.Regex.Matches(original, @"[A-Za-z]+"))
                {
                    var range = document.Clone(); range.MoveEndpointByRange(TextPatternRangeEndpoint.End, range, TextPatternRangeEndpoint.Start);
                    range.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, word.Index + word.Length); range.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, word.Index); words.Add(range);
                }
                awaitingPaste = false; armed = true; expires = Environment.TickCount64 + 15000;
                Automation.AddAutomationEventHandler(TextPattern.TextSelectionChangedEvent, element!, TreeScope.Element, selectionHandler);
                Interlocked.Exchange(ref dirty, 0);
                return new { status = "armed" };
            }
            if (action == "observe" && armed)
            {
                if (Environment.TickCount64 >= expires || stopped) return new { status = "stopped" };
                if (Volatile.Read(ref dirty) == 0 || Environment.TickCount64 - lastKey < 500) return new { status = "active" };
                if (editStart == null || editLimit == null || Volatile.Read(ref budget) != 0 || Volatile.Read(ref selectionBudget) != 0) return new { status = "stopped" };
                // All edits were witnessed within one original word. Never read after outside/unwitnessed input.
                var current = pattern.GetSelection(); var document = pattern.DocumentRange;
                if (current.Length != 1 || current[0].CompareEndpoints(TextPatternRangeEndpoint.Start, current[0], TextPatternRangeEndpoint.End) != 0 || current[0].CompareEndpoints(TextPatternRangeEndpoint.Start, editStart, TextPatternRangeEndpoint.Start) < 0 || current[0].CompareEndpoints(TextPatternRangeEndpoint.End, editLimit, TextPatternRangeEndpoint.End) > 0) return new { status = "stopped" };
                if (Volatile.Read(ref stopped) || Volatile.Read(ref budget) != 0) return new { status = "stopped" };
                string after = Read(document, Math.Min(4096, original.Length + 100));
                stopped = true;
                var candidate = CorrectionLease.Candidate(original, after);
                return candidate == null ? new { status = "stopped" } : new { status = "candidate", original = candidate.Original, replacement = candidate.Replacement };
            }
            return new { status = "stopped" };
        }
        var input = new System.Collections.Concurrent.ConcurrentQueue<string>();
        int inputEnded = 0;
        _ = Task.Run(() => { string? line; while ((line = Console.ReadLine()) != null && line.Length <= 70000) input.Enqueue(line); Volatile.Write(ref inputEnded, 1); });
        try
        {
            while (Volatile.Read(ref inputEnded) == 0 || !input.IsEmpty)
            {
                Native.PumpMessages();
                if (!input.TryDequeue(out var line)) { Thread.Sleep(5); continue; }
                object result;
                try { using var request = JsonDocument.Parse(line); result = Handle(request.RootElement); }
                catch { stopped = true; result = new { status = "unavailable" }; }
                Console.WriteLine(JsonSerializer.Serialize(result)); Console.Out.Flush();
            }
        }
        finally
        {
            if (keyboard != 0) Native.UnhookWindowsHookEx(keyboard); if (mouse != 0) Native.UnhookWindowsHookEx(mouse);
            if (focusHook != 0) Native.UnhookWinEvent(focusHook); if (foregroundHook != 0) Native.UnhookWinEvent(foregroundHook);
            if (element != null)
            {
                try { Automation.RemoveAutomationEventHandler(TextPattern.TextChangedEvent, element, handler); } catch { }
                if (commandSelection) { try { Automation.RemoveAutomationEventHandler(TextPattern.TextSelectionChangedEvent, element, handler); } catch { } }
                else { try { Automation.RemoveAutomationEventHandler(TextPattern.TextSelectionChangedEvent, element, selectionHandler); } catch { } }
            }
            original = "";
        }
    }
}
