using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using Sona.Core;

namespace Sona.Windows;

// Owns exactly one dictation shortcut. Retired command bindings are never registered.
internal sealed class HotkeyService : IDisposable
{
    private const int Id = 0x534F;
    private readonly HwndSource source = new(new HwndSourceParameters("Sona shortcut receiver") { Width = 0, Height = 0, ParentWindow = new nint(-3) });
    private readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    private readonly ModifierTap tap = new();
    private bool enabled;
    private int generation;
    private readonly Native.HookProc hookProc;
    private readonly bool allowSyntheticForTests;
    private Shortcut shortcut = new();
    private nint hook;
    public event Action? Triggered;

    public HotkeyService(bool allowSyntheticForTests = false)
    {
        this.allowSyntheticForTests = allowSyntheticForTests;
        hookProc = KeyboardHook; source.AddHook(Message);
    }
    public void Configure(Shortcut value)
    {
        var old = shortcut; bool wasEnabled = enabled;
        Disable();
        try
        {
            if (!value.IsValid) throw new ArgumentException("Choose a supported shortcut.");
            shortcut = value;
            if (value.IsModifierOnly)
            {
                hook = Native.SetWindowsHookEx(Native.WhKeyboardLl, hookProc, Native.GetModuleHandle(null), 0);
                if (hook == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows could not listen for this modifier. Choose a chord instead.");
            }
            else if (!Native.RegisterHotKey(source.Handle, Id, value.Modifiers | 0x4000, (uint)value.VirtualKey))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "This shortcut is already used or reserved by Windows. Choose another.");
            enabled = true;
        }
        catch
        {
            Disable(); shortcut = old;
            if (wasEnabled) { try { Configure(old); } catch { throw new InvalidOperationException("The new shortcut failed and the previous shortcut could not be restored. Reopen Settings to choose an available key."); } }
            throw;
        }
    }
    public void Disable()
    {
        enabled = false; generation++;
        Native.UnregisterHotKey(source.Handle, Id);
        if (hook != 0) { Native.UnhookWindowsHookEx(hook); hook = 0; }
        tap.Reset();
    }
    private nint Message(nint window, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == Native.WmHotkey && wParam.ToInt32() == Id) { handled = true; Fire(); }
        return 0;
    }
    private nint KeyboardHook(int code, nint wParam, nint data)
    {
        if (code >= 0 && (allowSyntheticForTests || (Marshal.ReadInt32(data, 8) & 0x10) == 0))
        {
            int message = wParam.ToInt32(), key = Marshal.ReadInt32(data);
            bool down = message is Native.WmKeydown or Native.WmSyskeydown;
            bool up = message is Native.WmKeyup or Native.WmSyskeyup;
            if (key != shortcut.VirtualKey) { if (down) tap.OtherKeyDown(); }
            else if (down)
            {
                bool other = new[] { 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C }.Any(k => k != key && Native.Held(k));
                tap.Down(Environment.TickCount64, other);
            }
            else if (up && tap.Up(Environment.TickCount64))
            {
                int expectedGeneration = generation;
                dispatcher.BeginInvoke(() => { if (enabled && expectedGeneration == generation) Fire(); });
            }
        }
        return Native.CallNextHookEx(hook, code, wParam, data);
    }
    private void Fire() { if (enabled) Triggered?.Invoke(); }
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
