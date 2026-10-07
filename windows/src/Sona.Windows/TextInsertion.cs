using System.Windows;
using System.Windows.Automation;
using System.Windows.Threading;
using Sona.Core;

namespace Sona.Windows;

internal sealed record FocusTarget(nint Window, uint Process, nint Focus, int[] RuntimeId);
internal sealed record FocusMetadata(int[] RuntimeId, bool IsPassword, bool Editable);
internal sealed record FocusRead(FocusMetadata? Metadata, string Status);

internal static class TextInsertion
{
    private static readonly object MetadataGate = new();
    private static Task<FocusRead>? pendingMetadata;
    private static long pendingStarted;
    private static int abandonedReads;
    private const int AbandonReadMs = 5000, MaxAbandonedReads = 2;
    private static FocusRead ReadMetadata()
    {
        try
        {
            var element = AutomationElement.FocusedElement;
            if (element == null) return new(null, "no_automation_focus");
            var c = element.Current;
            bool editable = c.ControlType == ControlType.Edit || c.ControlType == ControlType.Document;
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var value)) editable = !((ValuePattern)value).Current.IsReadOnly;
            var metadata = new FocusMetadata(element.GetRuntimeId(), c.IsPassword, editable && c.IsEnabled && c.IsKeyboardFocusable);
            string status = c.IsPassword ? "password" : !c.IsEnabled ? "disabled" : !c.IsKeyboardFocusable ? "not_focusable" : !editable ? "not_editable" : "ready";
            return new(metadata, status);
        }
        catch (Exception e) when (e is not OutOfMemoryException) { return new(null, "automation_" + e.GetType().Name); }
    }
    private static async Task<FocusRead> MetadataAsync()
    {
        Task<FocusRead> read;
        lock (MetadataGate)
        {
            // Keep all UIA calls off the WPF thread. A stuck external provider must not
            // accumulate abandoned work after each shortcut press, and must not block every
            // later read either: a read still running after AbandonReadMs is given up on (at
            // most MaxAbandonedReads at once) so the next press asks again.
            if (pendingMetadata is { IsCompleted: false })
            {
                if (Environment.TickCount64 - pendingStarted < AbandonReadMs || abandonedReads >= MaxAbandonedReads) return new(null, "automation_busy");
                abandonedReads++;
                pendingMetadata.ContinueWith(_ => { lock (MetadataGate) abandonedReads--; }, TaskScheduler.Default);
            }
            // A dedicated thread, so a provider that never answers cannot hold a thread-pool thread.
            read = pendingMetadata = Task.Factory.StartNew(ReadMetadata, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
            pendingStarted = Environment.TickCount64;
        }
        // Cold UIA initialization can exceed 600 ms on a fresh Windows session.
        try { return await read.WaitAsync(TimeSpan.FromMilliseconds(1500)); }
        catch (TimeoutException) { return new(null, "automation_timeout"); }
    }
    /// The focused app did not answer the accessibility read in time (not a cursor-placement problem).
    public static bool NotAnswering(string status) => status is "automation_busy" or "automation_timeout";
    public static async Task<FocusTarget?> CaptureAsync(bool allowOwnProcess = false)
        => (await CaptureWithStatusAsync(allowOwnProcess)).Target;
    internal static async Task<(FocusTarget? Target, string Status)> CaptureWithStatusAsync(bool allowOwnProcess = false)
    {
        var window = Native.GetForegroundWindow();
        var info = Native.FocusAt(window);
        if (window == 0) return (null, "no_foreground_window");
        if (info.Focus == 0) return (null, "no_native_focus");
        if (!allowOwnProcess && info.Process == Environment.ProcessId) return (null, "own_process");
        var read = await MetadataAsync();
        if (read.Metadata is not { IsPassword: false, Editable: true } metadata) return (null, read.Status);
        if (Native.GetForegroundWindow() != window || Native.FocusAt(window) != info) return (null, "focus_changed");
        return (new(window, info.Process, info.Focus, metadata.RuntimeId), "ready");
    }
    public static async Task<bool> PasteAsync(FocusTarget target, string text, Func<Task<bool>>? validate = null, Func<bool>? activity = null, OneShotCommit? commit = null)
    {
        // Never synthesize Ctrl+V while a physical modifier remains down.
        for (int i = 0; Native.AnyModifierHeld() && i < 50; i++) await Task.Delay(20);
        if (Native.AnyModifierHeld()) return false;
        var metadata = (await MetadataAsync()).Metadata;
        if (metadata is not { IsPassword: false, Editable: true }) return false;
        bool Matches()
        {
            var window = Native.GetForegroundWindow();
            var current = Native.FocusAt(window);
            return (activity?.Invoke() ?? true) && InsertionPolicy.MayPaste(target.Window, target.Process, target.Focus,
                window, current.Process, current.Focus, metadata.IsPassword, metadata.RuntimeId.SequenceEqual(target.RuntimeId));
        }
        if (!Matches() || validate != null && !await validate()) return false;
        // Every clipboard call runs on a short-lived STA thread of its own, never on the WPF thread:
        // delay-rendered formats make the clipboard owner render on demand and WPF's Clipboard class
        // sleeps between retries. Each step has a deadline. A missed one ends automatic paste (the text
        // stays in Copy last dictation) while the step finishes, or not, on its own thread.
        using var clipboard = await ClipboardSession.StartAsync();
        if (clipboard == null) return false; // Earlier clipboard threads are still stuck in an unresponsive owner.
        bool setRequested = false;
        try
        {
            // Eager snapshot before changing clipboard ownership. Refuse automatic paste if any
            // native format cannot be materialized; do not silently destroy rich clipboard data.
            if (!await clipboard.SnapshotAsync().WaitAsync(SnapshotDeadline)) return false;
            if (!Matches() || Native.AnyModifierHeld() || validate != null && !await validate()) return false;
            setRequested = true;
            if (!await clipboard.SetAsync(text).WaitAsync(SetDeadline)) return false;
            if (!Matches() || Native.AnyModifierHeld() || validate != null && !await validate()) return false;
            if (!Matches() || !(commit ?? new OneShotCommit()).TryBegin(true)) return false;
            if (Native.Paste() != 4) return false; // UIPI blocks input to higher-integrity apps.
            await Task.Delay(450); // Allow the focused app to consume a normal paste message.
            return true;
        }
        catch (Exception e) when (e is not OutOfMemoryException) { return false; }
        finally
        {
            // Queued behind the set on the clipboard thread, so it also runs after a set that missed its deadline.
            if (setRequested) { try { await clipboard.RestoreAsync().WaitAsync(RestoreDeadline); } catch (Exception e) when (e is not OutOfMemoryException) { } }
        }
    }
    private static readonly TimeSpan SnapshotDeadline = TimeSpan.FromMilliseconds(1000), SetDeadline = TimeSpan.FromMilliseconds(1500), RestoreDeadline = TimeSpan.FromMilliseconds(2000);
}

/// One paste's clipboard work on its own STA thread with a WPF dispatcher (OLE needs a pumping STA).
/// Steps run in order; disposing shuts the thread down after the steps already queued.
internal sealed class ClipboardSession : IDisposable
{
    private const int MaxLive = 3; // This paste plus at most two threads abandoned in an unresponsive owner.
    private static int live;
    private readonly Dispatcher dispatcher;
    // Touched only on the clipboard thread.
    private IDataObject? previous;
    private bool changed;
    private uint ours;

    private ClipboardSession(Dispatcher dispatcher) { this.dispatcher = dispatcher; }

    public static async Task<ClipboardSession?> StartAsync()
    {
        if (Interlocked.Increment(ref live) > MaxLive) { Interlocked.Decrement(ref live); return null; }
        var ready = new TaskCompletionSource<Dispatcher>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try { ready.TrySetResult(Dispatcher.CurrentDispatcher); Dispatcher.Run(); }
            catch (Exception e) { ready.TrySetException(e); }
            finally { Interlocked.Decrement(ref live); }
        }) { IsBackground = true, Name = "Sona clipboard" };
        try
        {
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
        }
        catch { Interlocked.Decrement(ref live); return null; }
        try { return new ClipboardSession(await ready.Task.WaitAsync(TimeSpan.FromSeconds(2))); }
        catch { return null; }
    }

    public Task<bool> SnapshotAsync() => dispatcher.InvokeAsync(() =>
    {
        try
        {
            var existing = Clipboard.GetDataObject();
            if (existing == null) return true;
            var snapshot = new DataObject();
            foreach (var format in existing.GetFormats(false))
            {
                var data = existing.GetData(format, false);
                if (data == null) return false;
                if (data is MemoryStream stream) data = new MemoryStream(stream.ToArray());
                snapshot.SetData(format, data, false);
            }
            previous = snapshot;
            return true;
        }
        catch (Exception e) when (e is not OutOfMemoryException) { return false; }
    }).Task;

    public Task<bool> SetAsync(string text) => dispatcher.InvokeAsync(() =>
    {
        try
        {
            var payload = new DataObject();
            payload.SetText(text, TextDataFormat.UnicodeText);
            // Prevent this transient payload from roaming or being included in clipboard history.
            payload.SetData("CanIncludeInClipboardHistory", new MemoryStream(BitConverter.GetBytes(0)));
            payload.SetData("CanUploadToCloudClipboard", new MemoryStream(BitConverter.GetBytes(0)));
            Clipboard.SetDataObject(payload, true);
            changed = true;
            ours = Native.GetClipboardSequenceNumber();
            return true;
        }
        catch (Exception e) when (e is not OutOfMemoryException) { return false; }
    }).Task;

    public Task RestoreAsync() => dispatcher.InvokeAsync(() =>
    {
        if (!changed) return;
        for (int attempt = 0; attempt < 4; attempt++)
        {
            if (!InsertionPolicy.MayRestoreClipboard(ours, Native.GetClipboardSequenceNumber())) break;
            try
            {
                if (previous == null) Clipboard.Clear(); else Clipboard.SetDataObject(previous, true);
                break;
            }
            catch (System.Runtime.InteropServices.ExternalException) { Thread.Sleep(50); }
            catch (Exception e) when (e is not OutOfMemoryException) { break; }
        }
    }).Task;

    public void Dispose()
    {
        try { dispatcher.BeginInvokeShutdown(DispatcherPriority.Normal); } catch (Exception e) when (e is not OutOfMemoryException) { }
    }
}
