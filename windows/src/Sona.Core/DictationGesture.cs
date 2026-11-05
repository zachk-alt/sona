namespace Sona.Core;

public enum DictationGestureEvent { None, Begin, Commit, Latch, Unlatch, Discard }

/// The Mac's dictation gesture (Sources/Murmur/HotKeyRouter.swift), for modifier keys and chords alike. The press
/// starts recording. A release after the hold threshold finishes it (hold to talk); a shorter tap latches hands-free
/// and the next tap finishes. Another key struck during the hold that started the dictation throws it away.
/// Only the physical state of the one shortcut key is kept, never other keys or characters.
public sealed class DictationGesture
{
    /// The Mac's threshold: its system double-click interval, 0.5 s by default.
    public const long HoldMilliseconds = 500;
    private long? pressedAt;
    private bool keyDown, invalid, latched, stopping, sawCleanPress;

    public bool Latched => latched;
    public bool Held => pressedAt.HasValue;
    /// The shortcut key is physically down, as far as the hook has seen.
    public bool KeyDown => keyDown;

    /// Volume, media and launch keys (VK_VOLUME_MUTE to VK_LAUNCH_APP2). Pressing one during a hold keeps the dictation.
    public static bool IgnoredKey(int virtualKey) => virtualKey is >= 0xAD and <= 0xB7;

    /// The shortcut key went down. clean: exactly the shortcut's own modifiers are held. The low-level hook has no
    /// repeat flag, so a down while the key is already down is auto-repeat, and never starts anything, including
    /// after a reset in the middle of a hold.
    public DictationGestureEvent Down(long milliseconds, bool clean)
    {
        bool repeat = keyDown;
        keyDown = true;
        if (repeat || pressedAt.HasValue || !clean) return DictationGestureEvent.None;
        sawCleanPress = true;
        pressedAt = milliseconds; invalid = false; stopping = latched;
        return latched ? DictationGestureEvent.None : DictationGestureEvent.Begin;
    }

    /// Any other key went down. During the hold that started a dictation it discards; during the tap that would stop a
    /// latched dictation it only voids that tap, so a shortcut typed while dictating hands-free loses nothing.
    /// A modifier let go is not a key struck: a chord's keys come up in any order at the end of a hold.
    public DictationGestureEvent OtherKey()
    {
        if (!pressedAt.HasValue) return DictationGestureEvent.None;
        bool discard = !invalid && !stopping;
        invalid = true;
        return discard ? DictationGestureEvent.Discard : DictationGestureEvent.None;
    }

    public DictationGestureEvent Up(long milliseconds)
    {
        keyDown = false;
        if (pressedAt is not long start) return DictationGestureEvent.None;
        pressedAt = null;
        if (invalid) { stopping = false; return DictationGestureEvent.None; }
        if (stopping) { stopping = false; latched = false; return DictationGestureEvent.Unlatch; }
        if (milliseconds - start >= HoldMilliseconds) return DictationGestureEvent.Commit;
        latched = true;
        return DictationGestureEvent.Latch;
    }

    /// RegisterHotKey's WM_HOTKEY for a chord. Windows runs low-level hooks before hotkeys, so a live hook has already
    /// seen this press. A press the hook missed (Windows silently removed it) works as a tap, so the chord still starts
    /// and stops dictation until the hook is installed again.
    public DictationGestureEvent Registered()
    {
        if (sawCleanPress) { sawCleanPress = false; return DictationGestureEvent.None; }
        bool live = latched || (pressedAt.HasValue && !invalid);
        pressedAt = null; keyDown = invalid = stopping = false;
        latched = !live;
        return live ? DictationGestureEvent.Unlatch : DictationGestureEvent.Begin;
    }

    /// The dictation ended, was declined or the shortcut was turned off. A key still held stays held, so its
    /// auto-repeat cannot begin again and its release does nothing. A press already seen stays seen, so its
    /// WM_HOTKEY is not taken for a missed one.
    public void Reset() { pressedAt = null; invalid = latched = stopping = false; }

    /// The hook was installed again (only while no modifier is held). A latched dictation stays latched, so the
    /// next tap still stops it.
    public void Rehooked() { pressedAt = null; keyDown = invalid = stopping = false; }

    // Left and right virtual keys of each RegisterHotKey modifier bit: Alt 1, Ctrl 2, Shift 4, Win 8.
    private static readonly (uint Bit, int Left, int Right)[] Families = [(1, 0xA4, 0xA5), (2, 0xA2, 0xA3), (4, 0xA0, 0xA1), (8, 0x5B, 0x5C)];

    /// Whether a press of the shortcut's key is the shortcut. A modifier alone is clean only with no other modifier
    /// held, the other side of its own family included (the Mac's rule). A chord needs exactly its own modifiers.
    public static bool Clean(Shortcut shortcut, Func<int, bool> held)
    {
        foreach (var (bit, left, right) in Families)
        {
            bool want = (shortcut.Modifiers & bit) != 0;
            bool down = (left != shortcut.VirtualKey && held(left)) || (right != shortcut.VirtualKey && held(right));
            if (want != down) return false;
        }
        return true;
    }
}
