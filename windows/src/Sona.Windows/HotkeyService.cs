using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using Sona.Core;

namespace Sona.Windows;

internal sealed class HotkeyService : IDisposable
{
    private const int Id = 0x534F;
    private readonly HwndSource source = new(new HwndSourceParameters("Sona shortcut receiver") { Width = 0, Height = 0, ParentWindow = new nint(-3) });
    private readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    private readonly ModifierTap tap = new();
    private readonly Native.HookProc hookProc;
    private Shortcut shortcut = new();
    private nint hook;
    public event Action? Triggered;

    public HotkeyService() { hookProc = KeyboardHook; source.AddHook(Message); }
    public void Configure(Shortcut value)
    {
        Disable();
        if (!value.IsValid) throw new ArgumentException("Choose a supported shortcut.");
        shortcut = value;
        if (value.IsModifierOnly)
        {
            hook = Native.SetWindowsHookEx(Native.WhKeyboardLl, hookProc, Native.GetModuleHandle(null), 0);
            if (hook == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows could not listen for this modifier. Choose a chord instead.");
        }
        else if (!Native.RegisterHotKey(source.Handle, Id, value.Modifiers | 0x4000, (uint)value.VirtualKey))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "This shortcut is already used or reserved by Windows. Choose another.");
    }
    public void Disable()
    {
        Native.UnregisterHotKey(source.Handle, Id);
        if (hook != 0) { Native.UnhookWindowsHookEx(hook); hook = 0; }
        tap.Reset();
    }
    private nint Message(nint window, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == Native.WmHotkey && wParam.ToInt32() == Id) { handled = true; Triggered?.Invoke(); }
        return 0;
    }
    private nint KeyboardHook(int code, nint wParam, nint data)
    {
        if (code >= 0)
        {
            int message = wParam.ToInt32();
            bool down = message is Native.WmKeydown or Native.WmSyskeydown;
            bool up = message is Native.WmKeyup or Native.WmSyskeyup;
            if ((Marshal.ReadInt32(data, 8) & 0x10) == 0) // Ignore synthetic input, including our paste.
            {
                // Compare immediately. No other key identity, text, or history is retained.
                if (Marshal.ReadInt32(data) != shortcut.VirtualKey) { if (down) tap.OtherKeyDown(); }
                else if (down)
                {
                    bool otherModifier = new[] { 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C }
                        .Any(k => k != shortcut.VirtualKey && Native.Held(k));
                    tap.Down(Environment.TickCount64, otherModifier);
                }
                else if (up && tap.Up(Environment.TickCount64)) dispatcher.BeginInvoke(() => Triggered?.Invoke());
            }
        }
        return Native.CallNextHookEx(hook, code, wParam, data); // Never suppress normal modifier/chord behavior.
    }
    public static string Label(Shortcut value)
    {
        var parts = new List<string>();
        if ((value.Modifiers & 2) != 0) parts.Add("Ctrl");
        if ((value.Modifiers & 1) != 0) parts.Add("Alt");
        if ((value.Modifiers & 4) != 0) parts.Add("Shift");
        if ((value.Modifiers & 8) != 0) parts.Add("Win");
        parts.Add(KeyInterop.KeyFromVirtualKey(value.VirtualKey).ToString());
        return string.Join(" + ", parts);
    }
    public void Dispose() { Disable(); source.RemoveHook(Message); source.Dispose(); }
}
