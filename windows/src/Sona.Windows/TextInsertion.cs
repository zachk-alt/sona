using System.Windows;
using System.Windows.Automation;
using Sona.Core;

namespace Sona.Windows;

internal sealed record FocusTarget(nint Window, uint Process, nint Focus, int[] RuntimeId);
internal sealed record FocusMetadata(int[] RuntimeId, bool IsPassword, bool Editable);
internal sealed record FocusRead(FocusMetadata? Metadata, string Status);

internal static class TextInsertion
{
    private static readonly object MetadataGate = new();
    private static Task<FocusRead>? pendingMetadata;
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
            // accumulate abandoned thread-pool work after each shortcut press.
            if (pendingMetadata is { IsCompleted: false }) return new(null, "automation_busy");
            read = pendingMetadata = Task.Run(ReadMetadata);
        }
        // Cold UIA initialization can exceed 600 ms on a fresh Windows session.
        try { return await read.WaitAsync(TimeSpan.FromMilliseconds(1500)); }
        catch (TimeoutException) { return new(null, "automation_timeout"); }
    }
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
        IDataObject? previous = null;
        uint ours = 0;
        bool changed = false;
        try
        {
            // Eager snapshot before changing clipboard ownership. Refuse automatic paste if any
            // native format cannot be materialized; do not silently destroy rich clipboard data.
            var existing = Clipboard.GetDataObject();
            if (existing != null)
            {
                var snapshot = new DataObject();
                foreach (var format in existing.GetFormats(false))
                {
                    var data = existing.GetData(format, false);
                    if (data == null) return false;
                    if (data is MemoryStream stream) data = new MemoryStream(stream.ToArray());
                    snapshot.SetData(format, data, false);
                }
                previous = snapshot;
            }
            if (!Matches() || Native.AnyModifierHeld() || validate != null && !await validate()) return false;
            var payload = new DataObject();
            payload.SetText(text, TextDataFormat.UnicodeText);
            // Prevent this transient payload from roaming or being included in clipboard history.
            payload.SetData("CanIncludeInClipboardHistory", new MemoryStream(BitConverter.GetBytes(0)));
            payload.SetData("CanUploadToCloudClipboard", new MemoryStream(BitConverter.GetBytes(0)));
            Clipboard.SetDataObject(payload, true);
            changed = true;
            ours = Native.GetClipboardSequenceNumber();
            if (!Matches() || Native.AnyModifierHeld() || validate != null && !await validate()) return false;
            if (!Matches() || !(commit ?? new OneShotCommit()).TryBegin(true)) return false;
            if (Native.Paste() != 4) return false; // UIPI blocks input to higher-integrity apps.
            await Task.Delay(450); // Allow the focused app to consume a normal paste message.
            return true;
        }
        catch (Exception e) when (e is not OutOfMemoryException) { return false; }
        finally
        {
            if (changed)
            {
                for (int attempt = 0; attempt < 4; attempt++)
                {
                    if (!InsertionPolicy.MayRestoreClipboard(ours, Native.GetClipboardSequenceNumber())) break;
                    try
                    {
                        if (previous == null) Clipboard.Clear(); else Clipboard.SetDataObject(previous, true);
                        break;
                    }
                    catch (System.Runtime.InteropServices.ExternalException) { await Task.Delay(50); }
                }
            }
        }
    }
}
