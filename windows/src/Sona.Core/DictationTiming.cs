namespace Sona.Core;

/// How long each step of a dictation may take, the Windows side of the Mac's AppState.Deadlines.
public static class DictationDeadlines
{
    /// Microphone open to its first live audio. Past this the recording panel shows anyway, without the start chime,
    /// so a slow microphone (a Bluetooth headset switching profile) never leaves a press with no feedback.
    public static readonly TimeSpan FirstAudio = TimeSpan.FromSeconds(1.5);
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
