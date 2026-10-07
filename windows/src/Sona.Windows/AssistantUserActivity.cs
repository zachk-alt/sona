using System.Runtime.InteropServices;

namespace Sona.Windows;

// Only alive during an explicit screen request. Never records key values or text.
internal sealed class AssistantUserActivity : IDisposable
{
    private readonly Native.HookProc keyboardCallback, mouseCallback;
    private nint keyboard, mouse;
    public bool Available => keyboard != 0 && mouse != 0;
    public AssistantUserActivity(Action cancel)
    {
        keyboardCallback = (code, message, data) =>
        {
            if (code >= 0 && message.ToInt32() is Native.WmKeydown or Native.WmSyskeydown && (Marshal.ReadInt32(data, 8) & 0x10) == 0) cancel();
            return Native.CallNextHookEx(keyboard, code, message, data);
        };
        mouseCallback = (code, message, data) =>
        {
            if (code >= 0 && message.ToInt32() is 0x201 or 0x204 or 0x207 or 0x20B or 0x20A or 0x20E && (Marshal.ReadInt32(data, 12) & 1) == 0)
            {
                var point = new ActionNative.Point { X = Marshal.ReadInt32(data), Y = Marshal.ReadInt32(data, 4) };
                nint hit = ActionNative.WindowFromPoint(point); Native.GetWindowThreadProcessId(hit, out var pid);
                // Approve/Cancel are explicit clicks in Sona's nonactivating panel.
                if (pid != Environment.ProcessId || ActionNative.GetAncestor(hit, 2) == AssistantCursor.ActiveWindow) cancel();
            }
            return Native.CallNextHookEx(mouse, code, message, data);
        };
        keyboard = Native.SetWindowsHookEx(Native.WhKeyboardLl, keyboardCallback, Native.GetModuleHandle(null), 0);
        mouse = Native.SetWindowsHookEx(Native.WhMouseLl, mouseCallback, Native.GetModuleHandle(null), 0);
    }
    public void Dispose() { if (keyboard != 0) Native.UnhookWindowsHookEx(keyboard); if (mouse != 0) Native.UnhookWindowsHookEx(mouse); keyboard = mouse = 0; }
}
