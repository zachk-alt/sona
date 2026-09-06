using System.Windows;
using System.Windows.Automation;
using Sona.Core;

namespace Sona.Windows;

internal sealed record FocusTarget(nint Window, uint Process, nint Focus, int[] RuntimeId);
internal sealed record FocusMetadata(int[] RuntimeId, bool IsPassword, bool Editable);

internal static class TextInsertion
{
    private static FocusMetadata? ReadMetadata()
    {
        try
        {
            var element = AutomationElement.FocusedElement;
            if (element == null) return null;
            var c = element.Current;
            bool editable = c.ControlType == ControlType.Edit || c.ControlType == ControlType.Document;
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var value)) editable = !((ValuePattern)value).Current.IsReadOnly;
            return new(element.GetRuntimeId(), c.IsPassword, editable && c.IsEnabled && c.IsKeyboardFocusable);
        }
        catch (Exception e) when (e is not OutOfMemoryException) { return null; }
    }
    private static async Task<FocusMetadata?> MetadataAsync()
    {
        try { return await Task.Run(ReadMetadata).WaitAsync(TimeSpan.FromMilliseconds(600)); }
        catch (TimeoutException) { return null; }
    }
    public static async Task<FocusTarget?> CaptureAsync(bool allowOwnProcess = false)
    {
        var window = Native.GetForegroundWindow();
        var info = Native.FocusAt(window);
        if (window == 0 || info.Focus == 0 || (!allowOwnProcess && info.Process == Environment.ProcessId)) return null;
        var metadata = await MetadataAsync();
        if (metadata is not { IsPassword: false, Editable: true } || Native.GetForegroundWindow() != window || Native.FocusAt(window) != info) return null;
        return new(window, info.Process, info.Focus, metadata.RuntimeId);
    }
    public static async Task<bool> PasteAsync(FocusTarget target, string text)
    {
        // Never synthesize Ctrl+V while a physical modifier remains down.
        for (int i = 0; Native.AnyModifierHeld() && i < 50; i++) await Task.Delay(20);
        if (Native.AnyModifierHeld()) return false;
        var metadata = await MetadataAsync();
        if (metadata is not { IsPassword: false, Editable: true }) return false;
        bool Matches()
        {
            var window = Native.GetForegroundWindow();
            var current = Native.FocusAt(window);
            return InsertionPolicy.MayPaste(target.Window, target.Process, target.Focus,
                window, current.Process, current.Focus, metadata.IsPassword, metadata.RuntimeId.SequenceEqual(target.RuntimeId));
        }
        if (!Matches()) return false;
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
            if (!Matches() || Native.AnyModifierHeld()) return false;
            var payload = new DataObject();
            payload.SetText(text, TextDataFormat.UnicodeText);
            // Prevent this transient payload from roaming or being included in clipboard history.
            payload.SetData("CanIncludeInClipboardHistory", new MemoryStream(BitConverter.GetBytes(0)));
            payload.SetData("CanUploadToCloudClipboard", new MemoryStream(BitConverter.GetBytes(0)));
            Clipboard.SetDataObject(payload, true);
            changed = true;
            ours = Native.GetClipboardSequenceNumber();
            if (!Matches() || Native.AnyModifierHeld()) return false;
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
