namespace Sona.Core;

/// How long each step of a dictation may take, the Windows side of the Mac's AppState.Deadlines.
public static class DictationDeadlines
{
    /// Microphone open to its first live audio. Past this the recording panel shows anyway, without the start chime,
    /// so a slow microphone (a Bluetooth headset switching profile) never leaves a press with no feedback.
    public static readonly TimeSpan FirstAudio = TimeSpan.FromSeconds(1.5);

    /// Press to microphone open, the Mac's micDelay. The shortcut can be an ordinary modifier, so a press that becomes
    /// Ctrl + C inside this is discarded before the microphone opens, the chime plays or a notice shows. The text
    /// field check runs inside it.
    public static readonly TimeSpan MicrophoneDelay = TimeSpan.FromMilliseconds(150);
    /// What is left of MicrophoneDelay at now, for a press at pressedAt (milliseconds on one clock).
    public static TimeSpan MicrophoneWait(long pressedAt, long now) =>
        TimeSpan.FromMilliseconds(Math.Clamp(MicrophoneDelay.TotalMilliseconds - (now - pressedAt), 0, MicrophoneDelay.TotalMilliseconds));

    /// Audio still captured after the stop press before the microphone closes. The press lands on or just after the
    /// last word, and WasapiCapture drops the packet it has not read yet when it stops, so a quick tap could clip the
    /// final consonant. The Mac's stopGrace; its audit found 100 to 150 ms enough.
    public static readonly TimeSpan StopGrace = TimeSpan.FromMilliseconds(120);

    /// Longest Parakeet may take before Whisper transcribes the same recording. The Mac's EnginePolicy.parakeetLimit,
    /// min(10 s, max(3 s, 2 s + seconds / 60)), is sized for Core ML. Windows decodes on the CPU: 0.019 s per recorded
    /// second at 6 threads on an M5 Max (2026-11-05 engine bench), and a low-power laptop may be ten times slower
    /// (0.19 s). 0.3 s per recorded second is 1.6 times that slow case and 16 times the measured one. The 6 s base
    /// covers stream setup and a cold reload of the 650 MB model after a dropped recognizer; a 10 s dictation gets 9 s,
    /// almost 5 times the slow case. The 45 s cap leaves Whisper most of the 120 s session for a long recording.
    public static TimeSpan ParakeetLimit(double audioSeconds) =>
        TimeSpan.FromSeconds(Math.Clamp(ParakeetBaseSeconds + Math.Max(0, audioSeconds) * ParakeetSecondsPerRecordedSecond, ParakeetBaseSeconds, ParakeetCapSeconds));
    public const double ParakeetBaseSeconds = 6, ParakeetSecondsPerRecordedSecond = 0.3, ParakeetCapSeconds = 45;

    /// Longest a Parakeet load inside a dictation may take before Whisper runs instead. Loads normally happen at
    /// launch; this one follows a dropped recognizer. Reading 661 MB from a slow disk at 50 MB/s takes about 13 s
    /// before ONNX Runtime builds its sessions, so 30 s leaves room without letting a hung load eat the session.
    public static readonly TimeSpan ParakeetLoad = TimeSpan.FromSeconds(30);
}

/// What the panel says when a dictation's work was cancelled. The session budget running out shows the Mac's stall
/// message; a cancel the user chose, or a quit, shows nothing.
public static class DictationOutcome
{
    public const string Stalled = "Transcription stalled. Try again.";
    public const string TextReady = "Text is ready in Copy last dictation.";
    public static string? Cancelled(bool byUser, bool quitting, bool textKept = false) => byUser || quitting ? null : textKept ? TextReady : Stalled;
}

public enum EngineOutcome { Completed, Busy, TimedOut }
public sealed record EngineRun<T>(EngineOutcome Outcome, T? Value);

/// One native decode at a time, with a time limit (the Mac's SpeechEngine.bounded). A native decode cannot be
/// interrupted, so one that overruns keeps running on its own and holds the gate until it really returns. The next
/// dictation then finds the engine busy and goes straight to the backup instead of queueing behind it.
public sealed class EngineGate
{
    private readonly SemaphoreSlim gate = new(1, 1);

    public bool Busy => gate.CurrentCount == 0;

    /// Load or release work that may wait its turn. It never runs on the caller's thread.
    public async Task RunAsync(Action work)
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try { await Task.Run(work).ConfigureAwait(false); }
        finally { gate.Release(); }
    }

    /// Work that runs only if nothing else holds the gate.
    public bool TryRun(Action work)
    {
        if (!gate.Wait(0)) return false;
        try { work(); return true; }
        finally { gate.Release(); }
    }

    /// Busy when the gate is held; TimedOut after the limit, with the work left running. Work that finishes after the
    /// caller stopped waiting (the limit or a cancellation) hands its value to late. A failure in time is rethrown.
    public Task<EngineRun<T>> RunBoundedAsync<T>(Func<T> work, TimeSpan limit, CancellationToken cancellation, Action<T>? late = null) =>
        RunBoundedAsync(decoding => { decoding(); return work(); }, limit, limit, cancellation, late);

    /// The same, for work that sets up first (a model load). Setup gets its own allowance, and the decode limit starts
    /// when the work calls decoding, so a slow load never eats the decode's time.
    public async Task<EngineRun<T>> RunBoundedAsync<T>(Func<Action, T> work, TimeSpan setupLimit, TimeSpan limit, CancellationToken cancellation, Action<T>? late = null)
    {
        cancellation.ThrowIfCancellationRequested();
        if (!gate.Wait(0)) return new(EngineOutcome.Busy, default);
        var decoding = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Task<T> decode;
        try { decode = Task.Run(() => { try { return work(() => decoding.TrySetResult()); } finally { gate.Release(); } }, CancellationToken.None); }
        catch { gate.Release(); throw; }
        using var timer = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        var first = await Task.WhenAny(decode, decoding.Task, Task.Delay(setupLimit, timer.Token)).ConfigureAwait(false);
        if (first == decoding.Task) first = await Task.WhenAny(decode, Task.Delay(limit, timer.Token)).ConfigureAwait(false);
        if (first == decode)
        {
            timer.Cancel();
            return new(EngineOutcome.Completed, await decode.ConfigureAwait(false));
        }
        _ = decode.ContinueWith(done =>
        {
            if (done.IsFaulted) _ = done.Exception; // Observed: an abandoned failure is not an unhandled one.
            else if (done.IsCompletedSuccessfully) late?.Invoke(done.Result);
        }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        cancellation.ThrowIfCancellationRequested();
        return new(EngineOutcome.TimedOut, default);
    }
}

[Flags]
public enum RecordingCue { None = 0, Show = 1, Chime = 2 }

/// When a recording becomes visible (parity P-F6). The start chime, the panel's Recording state and the tray icon
/// wait for live audio, like the Mac, so the chime means the microphone is really listening. A microphone with no
/// live audio by DictationDeadlines.FirstAudio still gets the panel, and the chime waits for real audio. The stop cue
/// plays only when the start cue did.
public sealed class RecordingStart
{
    public bool Shown { get; private set; }
    public bool ChimePlayed { get; private set; }

    public RecordingCue AudioArrived()
    {
        var cue = RecordingCue.None;
        if (!ChimePlayed) { ChimePlayed = true; cue |= RecordingCue.Chime; }
        if (!Shown) { Shown = true; cue |= RecordingCue.Show; }
        return cue;
    }

    public RecordingCue DeadlinePassed()
    {
        if (Shown) return RecordingCue.None;
        Shown = true;
        return RecordingCue.Show;
    }

    public bool StopCue => ChimePlayed;
}

/// Finds a capture's first live audio: the first 30 ms window above digital silence. NAudio zeroes the packets a
/// device flags silent but still delivers them, so the first callback alone can arrive while a Bluetooth link is mute.
public sealed class LiveAudio
{
    private readonly int samplesPerWindow;
    private double sum;
    private int count;

    public LiveAudio(int sampleRate, int channels) =>
        samplesPerWindow = Math.Max(1, (int)Math.Round(Math.Max(1, sampleRate) * SpeechActivity.WindowSeconds)) * Math.Max(1, channels);

    public bool Heard { get; private set; }

    /// One interleaved sample. True exactly once, on the sample that completes the first live window.
    public bool Add(float sample)
    {
        if (Heard) return false;
        double value = float.IsFinite(sample) ? sample : 0;
        sum += value * value;
        if (++count < samplesPerWindow) return false;
        double meanSquare = sum / samplesPerWindow;
        sum = 0; count = 0;
        return Heard = SpeechActivity.Dbfs(meanSquare) > SpeechActivity.DigitalSilenceDbfs;
    }
}
