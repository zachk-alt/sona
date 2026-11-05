using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using Sona.Core;

namespace Sona.Windows;

// Owns exactly one dictation shortcut. Retired command bindings are never registered.
// The Mac's gesture for both kinds of shortcut (DictationGesture): the low-level hook sees each press and release.
// A chord is also registered with RegisterHotKey, which reserves it and keeps its key from the focused app, as before.
internal sealed class HotkeyService : IDisposable
{
    private const int Id = 0x534F;
    private readonly HwndSource source = new(new HwndSourceParameters("Sona shortcut receiver") { Width = 0, Height = 0, ParentWindow = new nint(-3) });
    private readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    private volatile bool enabled;
    private readonly bool allowSyntheticForTests;
    private Shortcut shortcut = new();
    private volatile ShortcutHook? hook;
    // Shared by the hook thread and WM_HOTKEY on this one, always under gate. A reset bumps epoch, so events queued
    // before it are dropped (the Mac's HotKeyMonitor generation).
    private readonly object gate = new();
    private DictationGesture gesture = new();
    private int epoch;
    public event Action<DictationGestureEvent>? Gesture;

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
            lock (gate) { gesture = new(); epoch++; }
            if (!value.IsModifierOnly && !Native.RegisterHotKey(source.Handle, Id, value.Modifiers | 0x4000, (uint)value.VirtualKey))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "This shortcut is already used or reserved by Windows. Choose another.");
            try { hook = ShortcutHook.Start(value, allowSyntheticForTests, this); }
            // Without the hook a chord still starts and stops dictation as a tap, through WM_HOTKEY.
            catch (Win32Exception) when (!value.IsModifierOnly) { }
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
        enabled = false;
        lock (gate) { gesture.Reset(); epoch++; }
        Native.UnregisterHotKey(source.Handle, Id);
        var old = hook; hook = null;
        old?.Dispose();
    }
    /// Windows silently removes a low-level hook it once timed out, and an app cannot detect that, so the
    /// hook is installed afresh after each dictation, on unlock and on resume (and every minute).
    /// Safe from any thread.
    public void Rearm() => hook?.Rearm();
    /// The dictation ended or was declined (the Mac's resetGesture): the next press begins afresh, and the release
    /// of a press still held does nothing.
    public void ResetGesture() { lock (gate) { gesture.Reset(); epoch++; } }
    private nint Message(nint window, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == Native.WmHotkey && wParam.ToInt32() == Id)
        {
            handled = true;
            // A press the hook did not see means Windows dropped the hook.
            if (enabled && Route(null, Step.Registered, 0, false)) Rearm();
        }
        return 0;
    }
    private enum Step { Down, Up, OtherKey, Registered }
    /// Called on the hook thread and on this one. Events are queued while locked, so they reach the app in the order
    /// the keys moved, and only while the epoch that produced them is current. A replaced hook's late callback is ignored.
    private bool Route(ShortcutHook? from, Step step, long milliseconds, bool clean)
    {
        lock (gate)
        {
            if (from != null && from != hook) return false;
            var result = step switch
            {
                Step.Down => gesture.Down(milliseconds, clean),
                Step.Up => gesture.Up(milliseconds),
                Step.OtherKey => gesture.OtherKey(),
                _ => gesture.Registered()
            };
            if (result == DictationGestureEvent.None) return false;
            int expected = epoch;
            dispatcher.BeginInvoke(() =>
            {
                bool current; lock (gate) current = expected == epoch;
                if (enabled && current) Gesture?.Invoke(result);
            });
            return true;
        }
    }
    private void Rehooked(ShortcutHook from) { lock (gate) if (from == hook) gesture.Rehooked(); }
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

    /// The shortcut's WH_KEYBOARD_LL hook, installed on and serviced by its own thread with its own message
    /// loop. Windows calls a low-level hook through the installing thread's message loop and silently removes
    /// it after a timeout, so it must never wait behind the WPF thread (clipboard, audio device and panel
    /// work), and every keystroke on the system would wait with it. The Mac event tap runs on its own thread
    /// for the same reason (Sources/Murmur/HotKeyMonitor.swift). It never swallows a key.
    private sealed class ShortcutHook : IDisposable
    {
        private const uint WmQuit = 0x0012, WmTimer = 0x0113, WmRearm = 0x8001; // WM_APP + 1.
        private const uint RearmEveryMs = 60_000, RetryMs = 250;
        private readonly Shortcut shortcut;
        private readonly bool allowSynthetic;
        private readonly HotkeyService owner;
        private readonly Native.HookProc proc; // Rooted for as long as the hook can call it.
        private static readonly Func<int, bool> Held = Native.Held;
        private readonly ManualResetEventSlim started = new();
        private readonly Thread thread;
        private readonly object gate = new();
        private uint threadId;
        private bool disposed;
        private nint hook;
        private nuint retry;
        private int startError;

        private ShortcutHook(Shortcut shortcut, bool allowSynthetic, HotkeyService owner)
        {
            this.shortcut = shortcut; this.allowSynthetic = allowSynthetic; this.owner = owner;
            proc = Callback;
            thread = new Thread(Run) { IsBackground = true, Name = "Sona shortcut hook" };
        }

        public static ShortcutHook Start(Shortcut shortcut, bool allowSynthetic, HotkeyService owner)
        {
            var hook = new ShortcutHook(shortcut, allowSynthetic, owner);
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

        // Never re-hook in the middle of a press: the release would arrive without its press and the gesture would be lost.
        private void RequestRearm()
        {
            if (Native.AnyModifierHeld() || Native.Held(shortcut.VirtualKey))
            {
                if (retry == 0) retry = SetTimer(0, 0, RetryMs, 0);
                return;
            }
            if (retry != 0) { KillTimer(0, retry); retry = 0; }
            if (hook != 0) Native.UnhookWindowsHookEx(hook);
            owner.Rehooked(this);
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
                // Only key downs of other keys count: a chord's modifiers come up in any order at the end of a hold.
                if (pressed != shortcut.VirtualKey) { if (down) owner.Route(this, Step.OtherKey, 0, false); }
                else if (down) owner.Route(this, Step.Down, Environment.TickCount64, DictationGesture.Clean(shortcut, Held));
                else if (up) owner.Route(this, Step.Up, Environment.TickCount64, false);
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
