using System.Runtime.InteropServices;
using Sona.Core;

namespace Sona.Windows;

// Session-scoped invalidation only. No key text, key identity history or pointer coordinates.
internal sealed class SessionActivity : IDisposable
{
    private readonly Native.HookProc keyboardCallback, mouseCallback;
    private readonly Native.WinEventProc focusCallback;
    private nint keyboard, mouse, foreground, focus;
    private int changed;
    private readonly FocusTarget target;
    public bool Unchanged => Volatile.Read(ref changed) == 0 && Native.GetForegroundWindow() == target.Window && Native.FocusAt(target.Window) == (target.Process, target.Focus) && !Native.MenuActive();
    public bool Available => keyboard != 0 && mouse != 0 && foreground != 0 && focus != 0;
    public SessionActivity(FocusTarget target, Shortcut stopShortcut)
    {
        this.target = target;
        keyboardCallback = (code, message, data) =>
        {
            if (code >= 0 && message.ToInt32() is Native.WmKeydown or Native.WmSyskeydown && (Marshal.ReadInt32(data, 8) & 0x10) == 0)
            {
                int key = Marshal.ReadInt32(data);
                bool allowed = key == stopShortcut.VirtualKey || (stopShortcut.Modifiers & 2) != 0 && key is 0xA2 or 0xA3 || (stopShortcut.Modifiers & 1) != 0 && key is 0xA4 or 0xA5 || (stopShortcut.Modifiers & 4) != 0 && key is 0xA0 or 0xA1 || (stopShortcut.Modifiers & 8) != 0 && key is 0x5B or 0x5C;
                if (!allowed) Interlocked.Exchange(ref changed, 1);
            }
            return Native.CallNextHookEx(keyboard, code, message, data);
        };
        mouseCallback = (code, message, data) => { if (code >= 0 && message.ToInt32() is 0x201 or 0x204 or 0x207 or 0x20B) Interlocked.Exchange(ref changed, 1); return Native.CallNextHookEx(mouse, code, message, data); };
        focusCallback = (_, _, window, _, _, _, _) => { Interlocked.Exchange(ref changed, 1); };
        keyboard = Native.SetWindowsHookEx(Native.WhKeyboardLl, keyboardCallback, Native.GetModuleHandle(null), 0);
        mouse = Native.SetWindowsHookEx(Native.WhMouseLl, mouseCallback, Native.GetModuleHandle(null), 0);
        foreground = Native.SetWinEventHook(3, 3, 0, focusCallback, 0, 0, 0);
        focus = Native.SetWinEventHook(0x8005, 0x8005, 0, focusCallback, 0, 0, 0);
    }
    public void Dispose()
    {
        Interlocked.Exchange(ref changed, 1);
        if (keyboard != 0) Native.UnhookWindowsHookEx(keyboard); if (mouse != 0) Native.UnhookWindowsHookEx(mouse);
        if (foreground != 0) Native.UnhookWinEvent(foreground); if (focus != 0) Native.UnhookWinEvent(focus);
        keyboard = mouse = foreground = focus = 0;
    }
}
