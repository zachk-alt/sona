using System.Text;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using Whisper.net;
using Whisper.net.LibraryLoader;

namespace Sona.Windows;

internal sealed class Transcriber : IDisposable
{
    private WhisperFactory? factory;
    public Task<string> TranscribeAsync(byte[] recording, string modelPath, string language, CancellationToken cancellation) => Task.Run(async () =>
    {
        RuntimeOptions.RuntimeLibraryOrder = [RuntimeLibrary.Cpu, RuntimeLibrary.CpuNoAvx];
        factory ??= WhisperFactory.FromPath(modelPath);
        using var raw = new MemoryStream(recording, false);
        using var reader = new WaveFileReader(raw);
        ISampleProvider audio = reader.ToSampleProvider();
        if (audio.WaveFormat.Channels == 2) audio = new StereoToMonoSampleProvider(audio) { LeftVolume = 0.5f, RightVolume = 0.5f };
        if (audio.WaveFormat.Channels != 1) throw new NotSupportedException("Choose a mono or stereo microphone in Windows sound settings.");
        if (audio.WaveFormat.SampleRate != 16000) audio = new WdlResamplingSampleProvider(audio, 16000);
        using var wave = new MemoryStream();
        WaveFileWriter.WriteWavFileToStream(wave, audio.ToWaveProvider16());
        wave.Position = 0;
        using var processor = factory.CreateBuilder().WithLanguage(language).WithNoContext()
            .WithThreads(Math.Max(1, Math.Min(Environment.ProcessorCount - 1, 6))).Build();
        var text = new StringBuilder();
        await foreach (var segment in processor.ProcessAsync(wave, cancellation)) text.Append(segment.Text);
        return text.ToString().Trim();
    }, cancellation);
    public void Dispose() { factory?.Dispose(); factory = null; }
}
