using NAudio.CoreAudioApi;
using NAudio.Wave;
using Sona.Core;

namespace Sona.Windows;

internal sealed class AudioRecorder : IDisposable
{
    private readonly object gate = new();
    private WasapiCapture? capture;
    private MMDevice? device;
    private CaptureRecording? recording;
    public event Action<float>? Level;
    /// 48 voice bands, low to high, about ten times a second on the capture thread (Mac AudioCapture.updateSpectrum).
    public event Action<float[]>? Spectrum;
    private readonly float[] ring = new float[PanelSpectrum.AnalysisFrames], ordered = new float[PanelSpectrum.AnalysisFrames];
    private int ringNext, ringFilled, sinceSpectrum;
    public event Action<Exception?>? UnexpectedStop;
    /// The first live audio of a capture (Sona.Core.LiveAudio), raised once per Start with that capture's number.
    public event Action<int>? FirstAudio;
    public int Generation { get; private set; }
    private LiveAudio? live;
    private bool stopping;
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
        stopping = false; ringNext = 0; ringFilled = 0; sinceSpectrum = 0;
        using var enumerator = new MMDeviceEnumerator();
        device = string.IsNullOrEmpty(deviceId) ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications) : enumerator.GetDevice(deviceId);
        capture = new WasapiCapture(device);
        lock (gate)
        {
            Generation++;
            live = new LiveAudio(capture.WaveFormat.SampleRate, capture.WaveFormat.Channels);
            recording = new CaptureRecording(capture.WaveFormat);
        }
        capture.DataAvailable += OnData;
        capture.RecordingStopped += OnStopped;
        capture.StartRecording();
    }
    private void OnData(object? sender, WaveInEventArgs e)
    {
        float peak = 0;
        float[]? bands = null;
        bool firstLive = false;
        int generation;
        lock (gate)
        {
            // A capture disposed in the background must never write into the next session.
            if (recording == null || capture == null || !ReferenceEquals(sender, capture) || !recording.Write(e.Buffer, e.BytesRecorded)) return;
            generation = Generation;
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
                if (live?.Add(sample) == true) firstLive = true;
                if (index % channels == 0)
                {
                    // First channel only, like the Mac tap.
                    ring[ringNext] = finite ? sample : 0;
                    ringNext = (ringNext + 1) % ring.Length;
                    ringFilled = Math.Min(ringFilled + 1, ring.Length);
                    sinceSpectrum++;
                }
                if (!finite) continue;
                peak = Math.Max(peak, Math.Abs(sample));
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
        if (firstLive) FirstAudio?.Invoke(generation);
        Level?.Invoke(Math.Min(peak, 1));
        if (bands != null) Spectrum?.Invoke(bands);
    }
    private void OnStopped(object? sender, StoppedEventArgs e)
    {
        if (!ReferenceEquals(sender, capture)) return; // A late stop from an earlier, already replaced capture.
        CaptureRecording? current;
        lock (gate) current = recording;
        current?.Stopped(e.Exception);
        if (!stopping) UnexpectedStop?.Invoke(e.Exception);
    }
    /// Everything captured, never an exception: a stop that errors or does not confirm within 5 s still returns the
    /// audio already recorded, and says how the capture ended.
    public async Task<CaptureResult> StopAsync()
    {
        CaptureRecording? current;
        lock (gate) current = recording;
        if (capture == null || current == null) return new([], CaptureEnd.Clean);
        stopping = true;
        try { if (!current.HasStopped) capture.StopRecording(); }
        catch (Exception e) when (e is not OutOfMemoryException) { return new(current.Seal(), CaptureEnd.Failed, e); }
        return await current.FinishAsync(TimeSpan.FromSeconds(5));
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
        lock (gate) { recording?.Dispose(); recording = null; }
    }
}
