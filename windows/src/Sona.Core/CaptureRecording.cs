using NAudio.Wave;

namespace Sona.Core;

public enum CaptureEnd { Clean, Failed, TimedOut }
public sealed record CaptureResult(byte[] Wav, CaptureEnd End, Exception? Error = null);

/// One capture's audio, kept as a WAV in memory and handed back whole however the capture ends: a clean stop, a stop
/// that errors or never confirms, or a microphone that goes away mid-dictation. The Mac's capture.stop() never
/// throws, and the audio already delivered stays with the transcriber; this matches it, so a driver fault at the
/// stop tap or an unplugged headset no longer loses the words already spoken.
public sealed class CaptureRecording : IDisposable
{
    private readonly object gate = new();
    private readonly MemoryStream memory = new();
    private WaveFileWriter? writer;
    private readonly TaskCompletionSource<Exception?> stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public CaptureRecording(WaveFormat format) => writer = new WaveFileWriter(memory, format);

    /// False once the recording is sealed: a capture thread that outlives its stop never writes into the result.
    public bool Write(byte[] buffer, int count)
    {
        lock (gate)
        {
            if (writer == null) return false;
            writer.Write(buffer, 0, count);
            return true;
        }
    }

    /// The capture reported its end, cleanly or with the device's error.
    public void Stopped(Exception? error)
    {
        Seal();
        stopped.TrySetResult(error);
    }

    public bool HasStopped => stopped.Task.IsCompleted;

    /// Waits up to the deadline for the capture to confirm its stop, then returns everything captured.
    public async Task<CaptureResult> FinishAsync(TimeSpan deadline)
    {
        try
        {
            var error = await stopped.Task.WaitAsync(deadline).ConfigureAwait(false);
            return new(Seal(), error == null ? CaptureEnd.Clean : CaptureEnd.Failed, error);
        }
        catch (TimeoutException e) { return new(Seal(), CaptureEnd.TimedOut, e); }
    }

    /// Closes the WAV so its header holds the real data length. Later writes are dropped.
    public byte[] Seal()
    {
        lock (gate)
        {
            writer?.Dispose(); writer = null; // Also closes the memory stream; ToArray still works on it.
            return memory.ToArray();
        }
    }

    public void Dispose() => Seal();
}
