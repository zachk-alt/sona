namespace Sona.Core;

public enum ConversationGestureEvent { None, Dismiss, BeginFollowUp, FinishFollowUp, CancelFollowUp, CancelRequest }

// Tracks only the configured assistant press and whether it became a chord.
// The answer-visible state is frozen on key down, never inferred on release.
public sealed class ConversationGesture
{
    public const int HoldMilliseconds = 350;
    private long? pressedAt;
    private bool blocked, started;
    public bool Active => pressedAt.HasValue;
    public bool Down(long milliseconds, bool answerVisible, bool otherKeyHeld)
    {
        if (Active || !answerVisible) return false;
        pressedAt = milliseconds; blocked = otherKeyHeld; started = false; return true;
    }
    public ConversationGestureEvent Tick(long milliseconds)
    {
        if (pressedAt is not long start || blocked || started || milliseconds - start < HoldMilliseconds) return ConversationGestureEvent.None;
        started = true; return ConversationGestureEvent.BeginFollowUp;
    }
    public ConversationGestureEvent OtherKey()
    {
        if (!Active || blocked) return ConversationGestureEvent.None;
        blocked = true;
        if (!started) return ConversationGestureEvent.None;
        started = false; return ConversationGestureEvent.CancelFollowUp;
    }
    public ConversationGestureEvent Up(long milliseconds)
    {
        var result = blocked || pressedAt is not long start ? ConversationGestureEvent.None
            : started ? ConversationGestureEvent.FinishFollowUp
            : milliseconds - start is >= 0 and < HoldMilliseconds ? ConversationGestureEvent.Dismiss
            : ConversationGestureEvent.None;
        Reset(); return result;
    }
    public void Reset() { pressedAt = null; blocked = started = false; }
}
