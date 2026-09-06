using System.Runtime.InteropServices;

namespace Sona.Windows;

internal static class Native
{
    public const int GwlExStyle = -20, WsExNoActivate = 0x08000000, WsExToolWindow = 0x80;
    public const int WhKeyboardLl = 13, WmKeydown = 0x100, WmKeyup = 0x101, WmSyskeydown = 0x104, WmSyskeyup = 0x105, WmHotkey = 0x312;
    public delegate nint HookProc(int code, nint wParam, nint lParam);
    [DllImport("user32.dll")] public static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(nint window, int id);
    [DllImport("user32.dll", SetLastError = true)] public static extern nint SetWindowsHookEx(int id, HookProc callback, nint module, uint thread);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")] public static extern nint CallNextHookEx(nint hook, int code, nint wParam, nint lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern nint GetModuleHandle(string? module);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static extern nint GetWindowLongPtr(nint window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] public static extern nint SetWindowLongPtr(nint window, int index, nint value);
    [DllImport("user32.dll")] public static extern bool ShowWindow(nint window, int command);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint count, Input[] input, int size);
    [DllImport("user32.dll")] public static extern bool IsWindow(nint window);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(nint window, int attribute, ref int value, int size);

    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct GuiThreadInfo
    {
        public int Size; public uint Flags; public nint Active, Focus, Capture, MenuOwner, MoveSize, Caret; public Rect CaretRect;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Input { public uint Type; public InputUnion Data; }
    [StructLayout(LayoutKind.Explicit)] public struct InputUnion
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse; // Ensures native INPUT union size on x64.
    }
    [StructLayout(LayoutKind.Sequential)] public struct KeyboardInput { public ushort Key, Scan; public uint Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Sequential)] public struct MouseInput { public int X, Y; public uint Data, Flags, Time; public nuint Extra; }
    public static bool Held(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;
    public static bool AnyModifierHeld() => Held(0x10) || Held(0x11) || Held(0x12) || Held(0x5B) || Held(0x5C);
    public static (uint Process, nint Focus) FocusAt(nint window)
    {
        uint thread = GetWindowThreadProcessId(window, out var process);
        var info = new GuiThreadInfo { Size = Marshal.SizeOf<GuiThreadInfo>() };
        return GetGUIThreadInfo(thread, ref info) ? (process, info.Focus) : (process, 0);
    }
    public static uint Paste()
    {
        Input Key(ushort key, bool up) => new() { Type = 1, Data = new() { Keyboard = new() { Key = key, Flags = up ? 2u : 0u } } };
        Input[] keys = [Key(0x11, false), Key(0x56, false), Key(0x56, true), Key(0x11, true)];
        uint sent = SendInput((uint)keys.Length, keys, Marshal.SizeOf<Input>());
        if (sent is > 0 and < 4) SendInput(2, [Key(0x56, true), Key(0x11, true)], Marshal.SizeOf<Input>());
        return sent;
    }
}
