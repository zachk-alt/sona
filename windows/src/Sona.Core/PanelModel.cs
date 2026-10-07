namespace Sona.Core;

// Mac parity math for the dictation panel. Each piece names its Mac source so the
// two stay in step: Sources/Murmur/AudioCapture.swift (updateSpectrum),
// Sources/Murmur/WaveView.swift (tick and draw) and
// Sources/Murmur/StatusBarController.swift (LightScript, showIdle).
// Pure and UI-free, so the core tests check it on any OS.

/// The 48 voice bands behind the recording bars (AudioCapture.updateSpectrum).
public static class PanelSpectrum
{
    public const int BandCount = 48;
    public const int AnalysisFrames = 1024;

    // Log-spaced band centers, 80 Hz to 6 kHz, in Float like the Mac.
    private static readonly float[] Frequencies = Enumerable.Range(0, BandCount)
        .Select(i => 80f * MathF.Pow(6000f / 80f, i / (float)(BandCount - 1))).ToArray();

    // vDSP_hann_window with vDSP_HANN_NORM: a periodic Hann window scaled to a 1.633 peak.
    private static readonly float[] Window = Enumerable.Range(0, AnalysisFrames)
        .Select(n => (float)(0.81649658092772603 * (1 - Math.Cos(2 * Math.PI * n / AnalysisFrames)))).ToArray();

    public static float Frequency(int band) => Frequencies[band];

    /// Goertzel at each band center over the newest AnalysisFrames samples of one channel
    /// (oldest first), with the Mac's tilt and dB mapping. Bands land in 0...1.
    public static void Analyze(ReadOnlySpan<float> samples, float sampleRate, Span<float> bands)
    {
        if (samples.Length < AnalysisFrames) throw new ArgumentException("At least 1024 samples are required.", nameof(samples));
        if (bands.Length < BandCount) throw new ArgumentException("48 bands are required.", nameof(bands));
        if (!(sampleRate > 0)) throw new ArgumentOutOfRangeException(nameof(sampleRate));
        var x = samples[(samples.Length - AnalysisFrames)..];
        for (int b = 0; b < BandCount; b++)
        {
            float f = Frequencies[b];
            float k = 2 * MathF.PI * f / sampleRate;
            float coeff = 2 * MathF.Cos(k);
            float s1 = 0, s2 = 0;
            for (int i = 0; i < AnalysisFrames; i++)
            {
                float s0 = x[i] * Window[i] + coeff * s1 - s2;
                s2 = s1;
                s1 = s0;
            }
            float power = MathF.Max(0, s1 * s1 + s2 * s2 - coeff * s1 * s2);
            float magnitude = MathF.Sqrt(power) / AnalysisFrames * 2;
            float tilt = MathF.Pow(f / 250, 0.55f);
            float db = 20 * MathF.Log10(MathF.Max(magnitude * tilt, 1e-7f));
            bands[b] = Math.Clamp((db + 66) / 38, 0f, 1f);
        }
    }

    /// The synthetic voice of the Mac panel preview (main.swift PanelPreview), clock in seconds.
    public static void Synthetic(double clock, Span<float> bands)
    {
        for (int b = 0; b < BandCount; b++)
        {
            double x = b / (double)BandCount;
            double v = 0.45 + 0.3 * Math.Sin(clock * 2.6 + x * 9) + 0.2 * Math.Sin(clock * 6.1 + x * 23) - 0.25 * x;
            bands[b] = (float)Math.Clamp(v, 0.05, 1);
        }
    }
}

public enum BarMode { Idle, Recording, Processing }

/// The eased band levels behind the 75 bars (WaveView.swift). The Mac rates are per
/// 60 Hz tick; Advance converts them to elapsed time so a 120 Hz display or a late
/// frame covers the same distance.
public sealed class BarMotion
{
    public const int BarCount = 75;
    public const double BarWidth = 2, BarPitch = 4, MinHeight = 2, MaxHeight = 58;
    private readonly double[] targets = new double[PanelSpectrum.BandCount];
    private readonly double[] current = new double[PanelSpectrum.BandCount];
    private double processingElapsed;
    public BarMode Mode { get; private set; }
    public double Phase { get; private set; }

    public void StartRecording() => Mode = BarMode.Recording;
    public void StartProcessing() { Mode = BarMode.Processing; processingElapsed = 0; }

    /// WaveView.stopAnimating: idle, every band back to zero.
    public void Stop()
    {
        Array.Clear(targets); Array.Clear(current);
        Mode = BarMode.Idle; Phase = 0; processingElapsed = 0;
    }

    public void SetSpectrum(ReadOnlySpan<float> bands)
    {
        if (Mode != BarMode.Recording || bands.Length != targets.Length) return;
        for (int i = 0; i < bands.Length; i++) targets[i] = bands[i];
    }

    public void Advance(double seconds)
    {
        if (Mode == BarMode.Idle || !(seconds > 0)) return;
        double ticks = Math.Min(seconds * 60, 6); // A stalled frame catches up at most 0.1 s.
        if (Mode == BarMode.Processing)
        {
            processingElapsed += seconds;
            for (int i = 0; i < targets.Length; i++)
            {
                double x = i / (double)(targets.Length - 1);
                double crest = 0.5 + 0.5 * Math.Sin(x * Math.PI * 3.2 - processingElapsed * 4.2);
                targets[i] = 0.10 + 0.52 * crest * crest;
            }
        }
        for (int i = 0; i < current.Length; i++)
        {
            double up = 0.45 + 0.15 * (i % 3) / 2.0;
            double down = 0.10 + 0.06 * ((i * 7) % 5) / 4.0;
            double rate = targets[i] > current[i] ? up : down;
            current[i] += (targets[i] - current[i]) * (1 - Math.Pow(1 - rate, ticks));
        }
        Phase += 0.14 * ticks;
    }

    public double Level(int bar)
    {
        double position = bar / (double)(BarCount - 1) * (current.Length - 1);
        int lo = (int)position, hi = Math.Min(lo + 1, current.Length - 1);
        double frac = position - lo;
        return current[lo] * (1 - frac) + current[hi] * frac;
    }

    public double Height(int bar)
    {
        if (Mode == BarMode.Idle) return MinHeight;
        double shimmer = Mode == BarMode.Processing ? 1 : 0.9 + 0.1 * (Math.Sin(Phase + bar * 0.7) * 0.5 + 0.5);
        return Math.Max(MinHeight, MinHeight + Level(bar) * shimmer * (MaxHeight - MinHeight));
    }

    public double Alpha(int bar) => Mode == BarMode.Idle ? 0.3 : 0.55 + 0.45 * Math.Min(1, Level(bar) * 1.6);
}

/// Where the two processing lights are at one moment: script angles in radians and the tail opacity.
public readonly record struct LightPose(double One, double Two, double Tail);

/// The choreography of the two processing lights (StatusBarController.swift LightScript):
/// split, meet, pause, travel together, pause, on a fresh random script per run.
public sealed class LightScript
{
    /// Bearing in degrees (clockwise from straight up, about the glass center) where both
    /// lights rest at script angle 0. Measured on the Mac: bottom center, and a positive
    /// script angle turns counterclockwise on screen.
    public const double RestBearing = 179.4;
    private readonly List<double> times = [0], one = [0], two = [0], glowTimes = [0], glow = [1];
    private readonly List<bool> eased = [];
    public double Total => times[^1];

    public static LightScript Generate(Random random, double seconds = 90)
    {
        var s = new LightScript();
        const double twoPi = 2 * Math.PI;
        double a = 0, b = 0;
        bool firstClockwise = true;
        double Uniform(double lo, double hi) => lo + random.NextDouble() * (hi - lo);
        bool Coin() => random.Next(2) == 0;
        void Leg(double dt, double da, double db, bool ease)
        {
            a += da; b += db;
            s.times.Add(s.Total + dt); s.one.Add(a); s.two.Add(b); s.eased.Add(ease);
        }
        void Glow(double v, double at) { s.glowTimes.Add(at); s.glow.Add(v); }
        while (true)
        {
            bool homing = s.Total >= seconds - 8;
            double here = ((a % twoPi) + twoPi) % twoPi;
            double delta = homing ? (twoPi - here) % twoPi : Uniform(0.55 * Math.PI, 1.45 * Math.PI);
            double extra = 0;
            if (homing && delta < 0.5 * Math.PI) extra = twoPi;
            if (delta == 0) { delta = twoPi; extra = 0; }
            if (Coin()) firstClockwise = !firstClockwise;
            (double da, double db) = firstClockwise ? (delta + extra, -(twoPi - delta)) : (-(twoPi - delta), delta + extra);
            double t1 = Uniform(1.2, 2.0);
            Glow(0, s.Total + t1 * 0.25);
            Leg(t1, da, db, true);
            Glow(1, s.Total);
            Leg(Uniform(0.25, 0.5), 0, 0, false);
            if (homing) break;
            double d = Uniform(0.3 * Math.PI, 1.1 * Math.PI) * (Coin() ? 1 : -1);
            Leg(Uniform(0.9, 1.6), d, d, true);
            Leg(Uniform(0.25, 0.5), 0, 0, false);
            Glow(1, s.Total);
        }
        Glow(1, s.Total);
        return s;
    }

    /// The pose at a time since the lights started; the script repeats forever.
    public LightPose At(double elapsed)
    {
        double total = Total;
        double u = total > 0 ? ((elapsed % total) + total) % total : 0;
        int j = 0;
        while (j < times.Count - 2 && times[j + 1] <= u) j++;
        double span = times[j + 1] - times[j];
        double p = span > 0 ? Math.Clamp((u - times[j]) / span, 0, 1) : 1;
        double e = eased[j] ? EaseInOut(p) : p;
        double first = one[j] + (one[j + 1] - one[j]) * e;
        double second = two[j] + (two[j + 1] - two[j]) * e;
        return new LightPose(first, second, Piecewise(u));
    }

    private double Piecewise(double u)
    {
        double total = Total;
        double previousTime = 0, previousValue = glow[0];
        for (int k = 1; k < glowTimes.Count; k++)
        {
            double t = Math.Min(total, glowTimes[k]);
            if (u < t)
            {
                double span = t - previousTime;
                return span > 0 ? previousValue + (glow[k] - previousValue) * (u - previousTime) / span : glow[k];
            }
            previousTime = t; previousValue = glow[k];
        }
        return previousValue;
    }

    /// CAMediaTimingFunction easeInEaseOut: cubic-bezier(0.42, 0, 0.58, 1).
    public static double EaseInOut(double p)
    {
        if (p <= 0) return 0;
        if (p >= 1) return 1;
        double lo = 0, hi = 1, t = p;
        for (int i = 0; i < 40; i++)
        {
            t = (lo + hi) / 2;
            if (Bezier(t, 0.42, 0.58) < p) lo = t; else hi = t;
        }
        return Bezier(t, 0, 1);
    }

    private static double Bezier(double t, double p1, double p2)
    {
        double m = 1 - t;
        return 3 * m * m * t * p1 + 3 * m * t * t * p2 + t * t * t;
    }
}

/// Show and dismiss timing (StatusBarController.showError and showIdle).
public static class PanelTiming
{
    public const double DismissSeconds = 0.36, DismissLift = 6, ErrorSeconds = 3;

    public static double Smoothstep(double p)
    {
        p = Math.Clamp(p, 0, 1);
        return p * p * (3 - 2 * p);
    }
}
