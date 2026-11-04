namespace Sona.Core;

/// Decides whether a recording holds speech from short windows, not the whole-recording average.
/// The quietest windows set the room's noise floor. Speech is enough windows clearly above that floor
/// and above an absolute minimum, so steady room noise at any level types nothing.
public sealed class SpeechActivity
{
    public const double WindowSeconds = 0.03;
    /// Share of windows, quietest first, that marks the noise floor.
    public const double FloorPercentile = 0.10;
    /// A speech window is at least this far above the noise floor. Calibrated 2026-11-04 on synthetic
    /// white, pink, brown and mains-hum noise: the 5th-loudest window of steady noise sat at most 9.0 dB over
    /// the floor (300 s recordings, 20 seeds each), while speech at 10 dB signal-to-noise sat at least 12.5 dB over.
    public const double MarginDb = 11;
    /// A speech window is also at least this loud, so a bump in near-digital silence is not speech.
    public const double MinimumDbfs = -60;
    /// Windows quieter than this are digital zeros (a muted device or warm-up buffers) and say nothing about the room.
    public const double DigitalSilenceDbfs = -100;
    /// Speech needs this many speech windows in total (150 ms at 30 ms windows).
    public const int MinimumSpeechWindows = 5;
    /// The first 90 ms are left out: some devices fade in, and a fading window would pull the floor down.
    public const int LeadWindows = 3;

    private readonly int channels, framesPerWindow;
    private readonly List<double> windows = [];
    private double sum;
    private int channel, frames;

    public SpeechActivity(int sampleRate, int channels)
    {
        this.channels = Math.Max(1, channels);
        framesPerWindow = Math.Max(1, (int)Math.Round(Math.Max(1, sampleRate) * WindowSeconds));
    }

    /// One interleaved sample, in device channel order. Non-finite samples count as zero.
    public void Add(float sample)
    {
        double value = float.IsFinite(sample) ? sample : 0;
        sum += value * value;
        if (++channel < channels) return;
        channel = 0;
        if (++frames < framesPerWindow) return;
        windows.Add(sum / ((double)framesPerWindow * channels));
        sum = 0; frames = 0;
    }

    public int WindowCount => windows.Count;
    public bool HasSpeech => Decide(windows);

    public static double Dbfs(double meanSquare) => 10 * Math.Log10(Math.Max(meanSquare, 1e-14));

    /// Mean squares of complete windows in, speech or not out.
    public static bool Decide(IReadOnlyList<double> windowMeanSquares)
    {
        var levels = windowMeanSquares.Skip(LeadWindows).Select(Dbfs).Where(db => db > DigitalSilenceDbfs).ToArray();
        if (levels.Length < MinimumSpeechWindows) return false;
        Array.Sort(levels);
        double floor = levels[(int)Math.Floor(FloorPercentile * (levels.Length - 1))];
        double threshold = Math.Max(floor + MarginDb, MinimumDbfs);
        return levels.Count(db => db >= threshold) >= MinimumSpeechWindows;
    }

    /// Mono samples at one rate, for tests and offline checks.
    public static bool Detect(ReadOnlySpan<float> mono, int sampleRate)
    {
        var activity = new SpeechActivity(sampleRate, 1);
        foreach (float sample in mono) activity.Add(sample);
        return activity.HasSpeech;
    }
}
