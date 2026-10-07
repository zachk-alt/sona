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
    private bool enabled;
    private int generation;
    private readonly bool allowSyntheticForTests;
    private Shortcut shortcut = new();
    private volatile ModifierHook? modifierHook;
    public event Action? Triggered;

    public HotkeyService(bool allowSyntheticForTests = false)
    {
        this.allowSyntheticForTests = allowSyntheticForTests;
        source.AddHook(Message);
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
                int expectedGeneration = generation;
                modifierHook = ModifierHook.Start(value.VirtualKey, allowSyntheticForTests,
                    () => dispatcher.BeginInvoke(() => { if (enabled && expectedGeneration == generation) Fire(); }));
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
        var hook = modifierHook; modifierHook = null;
        hook?.Dispose();
    }
    /// Windows silently removes a low-level hook it once timed out, and an app cannot detect that, so the
    /// modifier hook is installed afresh after each dictation, on unlock and on resume (and every minute).
    /// Safe from any thread. Chords use RegisterHotKey and need nothing.
    public void Rearm() => modifierHook?.Rearm();
    private nint Message(nint window, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == Native.WmHotkey && wParam.ToInt32() == Id) { handled = true; Fire(); }
        return 0;
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

    /// The modifier-tap WH_KEYBOARD_LL hook, installed on and serviced by its own thread with its own message
    /// loop. Windows calls a low-level hook through the installing thread's message loop and silently removes
    /// it after a timeout, so it must never wait behind the WPF thread (clipboard, audio device and panel
    /// work), and every keystroke on the system would wait with it. The Mac event tap runs on its own thread
    /// for the same reason (Sources/Murmur/HotKeyMonitor.swift). The tap state lives only on this thread.
    private sealed class ModifierHook : IDisposable
    {
        private const uint WmQuit = 0x0012, WmTimer = 0x0113, WmRearm = 0x8001; // WM_APP + 1.
        private const uint RearmEveryMs = 60_000, RetryMs = 250;
        private static readonly int[] Modifiers = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C];
        private readonly int key;
        private readonly bool allowSynthetic;
        private readonly Action tapped;
        private readonly Native.HookProc proc; // Rooted for as long as the hook can call it.
        private readonly ModifierTap tap = new();
        private readonly ManualResetEventSlim started = new();
        private readonly Thread thread;
        private readonly object gate = new();
        private uint threadId;
        private bool disposed;
        private nint hook;
        private nuint retry;
        private int startError;

        private ModifierHook(int key, bool allowSynthetic, Action tapped)
        {
            this.key = key; this.allowSynthetic = allowSynthetic; this.tapped = tapped;
            proc = Callback;
            thread = new Thread(Run) { IsBackground = true, Name = "Sona shortcut hook" };
        }

        public static ModifierHook Start(int key, bool allowSynthetic, Action tapped)
        {
            var hook = new ModifierHook(key, allowSynthetic, tapped);
            hook.thread.Start();
            if (!hook.started.Wait(TimeSpan.FromSeconds(3)) || hook.startError != 0)
            {
                int error = hook.startError;
                hook.Dispose();
                throw new Win32Exception(error, "Windows could not listen for this modifier. Choose a chord instead.");
            }
            return hook;
        }

        public void Rearm()
        {
            lock (gate) if (threadId != 0 && !disposed) PostThreadMessage(threadId, WmRearm, 0, 0);
        }

        public void Dispose()
        {
            lock (gate) { disposed = true; if (threadId != 0) PostThreadMessage(threadId, WmQuit, 0, 0); }
            // The thread only runs short hook callbacks; a stuck one is a background thread and cannot keep Sona alive.
            if (thread.IsAlive && Thread.CurrentThread != thread) thread.Join(TimeSpan.FromSeconds(1));
        }

        private void Run()
        {
            PeekMessage(out _, 0, 0, 0, 0); // Creates this thread's message queue before anyone posts to it.
            hook = Install();
            if (hook == 0) { startError = Marshal.GetLastWin32Error(); if (startError == 0) startError = -1; started.Set(); return; }
            lock (gate)
            {
                if (disposed) { Native.UnhookWindowsHookEx(hook); hook = 0; started.Set(); return; }
                threadId = GetCurrentThreadId();
            }
            started.Set();
            nuint every = SetTimer(0, 0, RearmEveryMs, 0);
            try
            {
                while (GetMessage(out var message, 0, 0, 0) > 0)
                    if (message.Id is WmRearm or WmTimer) RequestRearm();
            }
            finally
            {
                lock (gate) threadId = 0;
                if (every != 0) KillTimer(0, every);
                if (retry != 0) KillTimer(0, retry);
                if (hook != 0) { Native.UnhookWindowsHookEx(hook); hook = 0; }
            }
        }

        private nint Install() => Native.SetWindowsHookEx(Native.WhKeyboardLl, proc, Native.GetModuleHandle(null), 0);

        // Never re-hook in the middle of a press: the release would arrive without its press and the tap would be lost.
        private void RequestRearm()
        {
            if (Native.AnyModifierHeld())
            {
                if (retry == 0) retry = SetTimer(0, 0, RetryMs, 0);
                return;
            }
            if (retry != 0) { KillTimer(0, retry); retry = 0; }
            if (hook != 0) Native.UnhookWindowsHookEx(hook);
            tap.Reset();
            hook = Install();
            // A failed install is retried on the next request; the minute timer keeps requesting.
        }

        private nint Callback(int code, nint wParam, nint data)
        {
            if (code >= 0 && (allowSynthetic || (Marshal.ReadInt32(data, 8) & 0x10) == 0))
            {
                int message = wParam.ToInt32(), pressed = Marshal.ReadInt32(data);
                bool down = message is Native.WmKeydown or Native.WmSyskeydown;
                bool up = message is Native.WmKeyup or Native.WmSyskeyup;
                if (pressed != key) { if (down) tap.OtherKeyDown(); }
                else if (down)
                {
                    bool other = false;
                    foreach (int k in Modifiers) if (k != pressed && Native.Held(k)) { other = true; break; }
                    tap.Down(Environment.TickCount64, other);
                }
                else if (up && tap.Up(Environment.TickCount64)) tapped();
            }
            return Native.CallNextHookEx(hook, code, wParam, data);
        }

        [DllImport("user32.dll")] private static extern int GetMessage(out Native.Message message, nint window, uint min, uint max);
        [DllImport("user32.dll")] private static extern bool PeekMessage(out Native.Message message, nint window, uint min, uint max, uint remove);
        [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint thread, uint message, nuint wParam, nint lParam);
        [DllImport("user32.dll")] private static extern nuint SetTimer(nint window, nuint id, uint elapse, nint callback);
        [DllImport("user32.dll")] private static extern bool KillTimer(nint window, nuint id);
        [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    }
}
