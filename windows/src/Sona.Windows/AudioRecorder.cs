using NAudio.CoreAudioApi;
using NAudio.Wave;
using Sona.Core;

namespace Sona.Windows;

internal sealed class AudioRecorder : IDisposable
{
    private readonly object gate = new();
    private WasapiCapture? capture;
    private MMDevice? device;
    private WaveFileWriter? writer;
    private MemoryStream? memory;
    private TaskCompletionSource<Exception?>? stopped;
    public event Action<float>? Level;
    /// 48 voice bands, low to high, about ten times a second on the capture thread (Mac AudioCapture.updateSpectrum).
    public event Action<float[]>? Spectrum;
    private readonly float[] ring = new float[PanelSpectrum.AnalysisFrames], ordered = new float[PanelSpectrum.AnalysisFrames];
    private int ringNext, ringFilled, sinceSpectrum;
    public event Action<Exception?>? UnexpectedStop;
    private bool stopping;
    private double energy;
    private long count;
    public bool HasSpeech => count > 0 && Math.Sqrt(energy / count) > 0.002;
    public static List<(string Id, string Name)> Devices()
    {
        using var enumerator = new MMDeviceEnumerator();
        return enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active).Select(d =>
        {
            using (d) return (d.ID, d.FriendlyName);
        }).ToList();
    }
    public void Start(string? deviceId)
    {
        Dispose();
        stopping = false; energy = 0; count = 0; ringNext = 0; ringFilled = 0; sinceSpectrum = 0;
        using var enumerator = new MMDeviceEnumerator();
        device = string.IsNullOrEmpty(deviceId) ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications) : enumerator.GetDevice(deviceId);
        capture = new WasapiCapture(device);
        memory = new MemoryStream();
        writer = new WaveFileWriter(memory, capture.WaveFormat);
        stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
        capture.DataAvailable += OnData;
        capture.RecordingStopped += OnStopped;
        capture.StartRecording();
    }
    private void OnData(object? sender, WaveInEventArgs e)
    {
        float peak = 0;
        float[]? bands = null;
        lock (gate)
        {
            // A capture disposed in the background must never write into the next session.
            if (writer == null || capture == null || !ReferenceEquals(sender, capture)) return;
            writer.Write(e.Buffer, 0, e.BytesRecorded);
            var format = capture.WaveFormat;
            bool floating = format.Encoding == WaveFormatEncoding.IeeeFloat ||
                format is WaveFormatExtensible ext && ext.SubFormat == new Guid("00000003-0000-0010-8000-00aa00389b71");
            int bytes = format.BitsPerSample / 8, channels = Math.Max(1, format.Channels);
            for (int i = 0, index = 0; bytes > 0 && i + bytes <= e.BytesRecorded; i += bytes, index++)
            {
                float sample = floating && bytes == 4 ? BitConverter.ToSingle(e.Buffer, i) : bytes == 2 ? BitConverter.ToInt16(e.Buffer, i) / 32768f :
                    bytes == 4 ? BitConverter.ToInt32(e.Buffer, i) / 2147483648f :
                    bytes == 3 ? ((e.Buffer[i] << 8) | (e.Buffer[i + 1] << 16) | (e.Buffer[i + 2] << 24)) / 2147483648f : 0;
                bool finite = float.IsFinite(sample);
                if (index % channels == 0)
                {
                    // First channel only, like the Mac tap.
                    ring[ringNext] = finite ? sample : 0;
                    ringNext = (ringNext + 1) % ring.Length;
                    ringFilled = Math.Min(ringFilled + 1, ring.Length);
                    sinceSpectrum++;
                }
                if (!finite) continue;
                peak = Math.Max(peak, Math.Abs(sample)); energy += sample * sample; count++;
            }
            // One analysis of the newest 1024 frames per 100 ms of audio, the Mac tap cadence.
            if (Spectrum != null && format.SampleRate > 0 && ringFilled == ring.Length && sinceSpectrum >= format.SampleRate / 10)
            {
                sinceSpectrum = 0;
                int tail = ring.Length - ringNext;
                Array.Copy(ring, ringNext, ordered, 0, tail);
                Array.Copy(ring, 0, ordered, tail, ringNext);
                bands = new float[PanelSpectrum.BandCount];
                PanelSpectrum.Analyze(ordered, format.SampleRate, bands);
            }
        }
        Level?.Invoke(Math.Min(peak, 1));
        if (bands != null) Spectrum?.Invoke(bands);
    }
    private void OnStopped(object? sender, StoppedEventArgs e)
    {
        if (!ReferenceEquals(sender, capture)) return; // A late stop from an earlier, already replaced capture.
        lock (gate) { writer?.Dispose(); writer = null; }
        stopped?.TrySetResult(e.Exception);
        if (!stopping) UnexpectedStop?.Invoke(e.Exception);
    }
    public async Task<byte[]> StopAsync()
    {
        if (capture == null || stopped == null) return [];
        stopping = true;
        capture.StopRecording();
        var error = await stopped.Task.WaitAsync(TimeSpan.FromSeconds(5));
        if (error != null) throw error;
        return memory?.ToArray() ?? [];
    }
    public void Dispose()
    {
        stopping = true;
        var old = capture; capture = null;
        var oldDevice = device; device = null;
        if (old != null) { old.DataAvailable -= OnData; old.RecordingStopped -= OnStopped; }
        // WasapiCapture.Dispose joins its capture thread with no timeout, and that thread can be stuck in a
        // wedged audio driver. Never wait for it on the WPF thread; Start always opens a fresh capture.
        if (old != null || oldDevice != null)
            _ = Task.Run(() =>
            {
                try { old?.Dispose(); } catch { }
                try { oldDevice?.Dispose(); } catch { }
            });
        lock (gate) { writer?.Dispose(); writer = null; memory?.Dispose(); memory = null; }
    }
}
