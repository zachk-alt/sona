using NAudio.Dsp;
using NAudio.Wave;

namespace Sona.Core;

/// The one conversion both speech engines hear, and the speech check judges: every channel averaged to mono, then a
/// windowed-sinc resample to 16 kHz. NAudio's WdlResamplingSampleProvider runs the same resampler in linear mode with
/// two IIR passes, which measured -11.7 dB at 7 kHz and let 9 to 10 kHz fold back in at -20 to -25 dB: dull consonants
/// plus hiss. The Mac's AVAudioConverter is flat to 7.5 kHz.
public static class SpeechAudio
{
    public const int SampleRate = 16000;
    // Measured 2026-11-05: sinc size 128 is flat within 0.1 dB to 7 kHz with every alias under -43 dB.
    // Size 64 still let 9 kHz fold back at -25 dB.
    private const int SincSize = 128, SincInterpolation = 32;

    /// A WAV recording (PCM or float, any rate and channel count) as 16 kHz mono float samples.
    public static float[] Mono16k(byte[] wav)
    {
        using var raw = new MemoryStream(wav, false);
        using var reader = new WaveFileReader(raw);
        var source = reader.ToSampleProvider();
        int channels = Math.Max(1, source.WaveFormat.Channels);
        var mono = new List<float>((int)Math.Min(int.MaxValue, reader.SampleCount));
        var buffer = new float[channels * 4096];
        var mixer = new MonoMixer(channels);
        int read;
        while ((read = source.Read(buffer, 0, buffer.Length)) > 0) mixer.Add(buffer.AsSpan(0, read), mono);
        return Resample(mono.ToArray(), source.WaveFormat.SampleRate);
    }

    /// Interleaved samples at the device rate and channel count in, 16 kHz mono out.
    public static float[] Mono16k(ReadOnlySpan<float> interleaved, int sampleRate, int channels) => Resample(Mono(interleaved, channels), sampleRate);

    /// Each frame's channels averaged, the same rule as the Mac. Stereo keeps the 0.5/0.5 mix it always had.
    /// Non-finite samples count as zero, so one bad sample cannot spread through the resampler.
    public static float[] Mono(ReadOnlySpan<float> interleaved, int channels)
    {
        var mono = new List<float>(interleaved.Length / Math.Max(1, channels));
        new MonoMixer(channels).Add(interleaved, mono);
        return mono.ToArray();
    }

    /// Mono samples at any rate in, 16 kHz out, exactly round(length * 16000 / rate) samples long.
    public static float[] Resample(float[] mono, int sampleRate)
    {
        if (sampleRate <= 0) throw new ArgumentOutOfRangeException(nameof(sampleRate));
        if (sampleRate == SampleRate) return mono;
        int expected = (int)Math.Round(mono.LongLength * (double)SampleRate / sampleRate);
        var output = new float[expected];
        var resampler = new WdlResampler();
        resampler.SetMode(true, 0, true, SincSize, SincInterpolation);
        resampler.SetFilterParms();
        // Output-driven: the resampler asks for the input each block needs. It lines the output up with the input
        // itself (an impulse lands on the same instant), so no latency trim is needed.
        resampler.SetFeedMode(false);
        resampler.SetRates(sampleRate, SampleRate);
        int written = 0, read = 0;
        while (written < expected)
        {
            int want = Math.Min(4096, expected - written);
            int need = resampler.ResamplePrepare(want, 1, out float[] input, out int offset);
            int take = Math.Clamp(mono.Length - read, 0, need);
            Array.Copy(mono, read, input, offset, take);
            // Past the end, silence flushes the filter's held-back tail, so the last word is kept.
            Array.Clear(input, offset + take, need - take);
            read += take;
            int got = resampler.ResampleOut(output, written, need, want, 1);
            if (got <= 0) break;
            written += got;
        }
        return output;
    }

    private sealed class MonoMixer(int channels)
    {
        private readonly int channels = Math.Max(1, channels);
        private double sum;
        private int channel;

        public void Add(ReadOnlySpan<float> interleaved, List<float> mono)
        {
            foreach (float sample in interleaved)
            {
                sum += float.IsFinite(sample) ? sample : 0;
                if (++channel < channels) continue;
                mono.Add((float)(sum / channels));
                sum = 0; channel = 0;
            }
        }
    }
}
