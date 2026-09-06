using NAudio.CoreAudioApi;
using NAudio.Wave;

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
        stopping = false; energy = 0; count = 0;
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
        lock (gate)
        {
            if (writer == null || capture == null) return;
            writer.Write(e.Buffer, 0, e.BytesRecorded);
            var format = capture.WaveFormat;
            bool floating = format.Encoding == WaveFormatEncoding.IeeeFloat ||
                format is WaveFormatExtensible ext && ext.SubFormat == new Guid("00000003-0000-0010-8000-00aa00389b71");
            int bytes = format.BitsPerSample / 8;
            for (int i = 0; bytes > 0 && i + bytes <= e.BytesRecorded; i += bytes)
            {
                float sample = floating && bytes == 4 ? BitConverter.ToSingle(e.Buffer, i) : bytes == 2 ? BitConverter.ToInt16(e.Buffer, i) / 32768f :
                    bytes == 4 ? BitConverter.ToInt32(e.Buffer, i) / 2147483648f :
                    bytes == 3 ? ((e.Buffer[i] << 8) | (e.Buffer[i + 1] << 16) | (e.Buffer[i + 2] << 24)) / 2147483648f : 0;
                if (!float.IsFinite(sample)) continue;
                peak = Math.Max(peak, Math.Abs(sample)); energy += sample * sample; count++;
            }
        }
        Level?.Invoke(Math.Min(peak, 1));
    }
    private void OnStopped(object? sender, StoppedEventArgs e)
    {
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
        if (old != null) { old.DataAvailable -= OnData; old.RecordingStopped -= OnStopped; old.Dispose(); }
        device?.Dispose(); device = null;
        lock (gate) { writer?.Dispose(); writer = null; memory?.Dispose(); memory = null; }
    }
}
