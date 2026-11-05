using Whisper.net;
using Whisper.net.LibraryLoader;
using Sona.Core;

namespace Sona.Windows;

/// What one dictation runs on: Whisper always (the backup), and Parakeet first when its verified folder is given.
internal sealed record SpeechRoute(string WhisperModelPath, string WhisperLanguage, string? ParakeetFolder);
internal sealed record Transcript(string Text, SpeechEngine Engine);

internal sealed class Transcriber : IDisposable
{
    private static int Threads => Math.Max(1, Math.Min(Environment.ProcessorCount - 1, 6));
    // Parakeet stays loaded between dictations. Its native decode cannot be interrupted, so one gate serializes
    // load, decode and release. A dictation stops waiting at its time limit or on cancel while the decode it started
    // finishes on its own, and a dictation that finds the gate held runs on Whisper instead of queueing.
    private readonly EngineGate parakeetGate = new();
    private ParakeetRecognizer? parakeet;
    private readonly ParakeetHealth parakeetHealth = new();
    public ParakeetHealth Health => parakeetHealth;
    /// A load, warm-up, release or overrun decode holds Parakeet; a dictation now runs on Whisper.
    internal bool ParakeetBusy => parakeetGate.Busy;

    /// A WAV recording, through the one conversion both engines share.
    public Task<Transcript> TranscribeAsync(byte[] recording, SpeechRoute route, CancellationToken cancellation) =>
        TranscribeAsync(SpeechAudio.Mono16k(recording), route, cancellation, null);
    public Task<string> TranscribeAsync(byte[] recording, string modelPath, string language, CancellationToken cancellation) =>
        TranscribeAsync(SpeechAudio.Mono16k(recording), modelPath, language, cancellation);

    /// Both engines hear the same 16 kHz mono samples (SpeechAudio.Mono16k).
    /// Parakeet first when the route has it and it has not failed; on a load or decode failure that dictation runs on
    /// Whisper. Failures are logged as fixed codes with the exception type only, never text. Parakeet gets
    /// DictationDeadlines.ParakeetLimit; past it, or while an earlier decode still holds Parakeet, Whisper transcribes the
    /// same samples. A Parakeet result that arrives after this call stopped waiting for it goes to late.
    public async Task<Transcript> TranscribeAsync(float[] samples, SpeechRoute route, CancellationToken cancellation, Action<string>? late)
    {
        if (route.ParakeetFolder != null && parakeetHealth.ShouldTry(route.ParakeetFolder))
        {
            try
            {
                string? text = await TranscribeParakeetAsync(samples, route.ParakeetFolder, cancellation, late);
                if (text != null) return new(text, SpeechEngine.Parakeet);
            }
            catch (Exception e) when (SpeechEngines.FallBackToWhisper(e, cancellation.IsCancellationRequested))
            {
                App.Log(e is ParakeetLoadException ? SpeechEngines.ParakeetLoadFailed : SpeechEngines.ParakeetDecodeFailed, e.InnerException ?? e);
            }
        }
        return new(await TranscribeAsync(samples, route.WhisperModelPath, route.WhisperLanguage, cancellation), SpeechEngine.Whisper);
    }

    /// Loads and warms Parakeet ahead of the first dictation, off the UI thread, so that dictation does not wait for
    /// it. A load failure is logged and marks the folder failed, so English keeps running on Whisper.
    public Task PreloadParakeetAsync(string folder) => Task.Run(async () =>
    {
        if (!parakeetHealth.ShouldTry(folder)) return;
        await parakeetGate.RunAsync(() =>
        {
            ParakeetRecognizer engine;
            try { engine = Load(folder); }
            catch (ParakeetLoadException e) { App.Log(SpeechEngines.ParakeetLoadFailed, e.InnerException ?? e); return; }
            // One short silent decode, like the Mac's load, so the first dictation does not pay for ONNX Runtime's
            // first-run setup. A failure here drops the recognizer the same way a failed dictation decode does.
            try { engine.Transcribe(new float[SpeechAudio.SampleRate]); }
            catch (Exception e)
            {
                App.Log(SpeechEngines.ParakeetDecodeFailed, e);
                parakeetHealth.DecodeFailed(folder);
                try { engine.Dispose(); } catch { }
                parakeet = null;
            }
        });
    });

    /// Frees the loaded Parakeet model, for a switch away from English. Skipped while a decode still runs.
    public void ReleaseParakeet() => parakeetGate.TryRun(() => { parakeet?.Dispose(); parakeet = null; });

    /// Null when Parakeet is busy or ran past its limit: the caller runs Whisper.
    private async Task<string?> TranscribeParakeetAsync(float[] samples, string folder, CancellationToken cancellation, Action<string>? late)
    {
        int abandoned = 0;
        var run = await parakeetGate.RunBoundedAsync(decoding =>
        {
            var engine = Load(folder);
            decoding();
            try { return engine.Transcribe(samples); }
            catch (Exception)
            {
                // The recognizer may be in a bad state: drop it, reload on the next dictation. A decode that already
                // ran out of time was counted then.
                if (Volatile.Read(ref abandoned) == 0) parakeetHealth.DecodeFailed(folder);
                try { engine.Dispose(); } catch { }
                parakeet = null;
                throw;
            }
        }, DictationDeadlines.ParakeetLoad, DictationDeadlines.ParakeetLimit(samples.Length / (double)SpeechAudio.SampleRate), cancellation, text =>
        {
            // Late: never a success that would clear the time-out, so a machine too slow for Parakeet stops using it.
            if (!string.IsNullOrWhiteSpace(text)) late?.Invoke(text);
        });
        switch (run.Outcome)
        {
            case EngineOutcome.Completed: parakeetHealth.Succeeded(folder); return run.Value!;
            case EngineOutcome.TimedOut:
                Interlocked.Exchange(ref abandoned, 1);
                // Counted like a failed decode: after MaximumDecodeFailures the folder is left to Whisper.
                parakeetHealth.DecodeFailed(folder);
                App.Log(SpeechEngines.ParakeetTimedOut, new TimeoutException());
                return null;
            default: return null; // Busy: an earlier decode, a load or a release still holds Parakeet.
        }
    }

    // Caller holds the gate.
    private ParakeetRecognizer Load(string folder)
    {
        if (parakeet != null && string.Equals(parakeet.Folder, folder, StringComparison.OrdinalIgnoreCase)) return parakeet;
        parakeet?.Dispose(); parakeet = null;
        try { parakeet = new ParakeetRecognizer(folder, Threads); return parakeet; }
        catch (Exception e) { parakeetHealth.LoadFailed(folder); throw new ParakeetLoadException(e); }
    }

    private WhisperFactory? factory;
    private string? factoryPath;
    // A processor whose dispose did not finish may still run on its factory. Such a factory is kept alive,
    // never freed under it, when a language change selects another model file.
    private bool processorMayLinger;
    private readonly List<WhisperFactory> retained = [];
    public Task<string> TranscribeAsync(float[] samples, string modelPath, string language, CancellationToken cancellation) => Task.Run(async () =>
    {
        RuntimeOptions.RuntimeLibraryOrder = [RuntimeLibrary.Cpu, RuntimeLibrary.CpuNoAvx];
        if (factory != null && !string.Equals(factoryPath, modelPath, StringComparison.OrdinalIgnoreCase))
        {
            if (processorMayLinger) retained.Add(factory); else factory.Dispose();
            factory = null; factoryPath = null; processorMayLinger = false;
        }
        factory ??= WhisperFactory.FromPath(modelPath);
        factoryPath = modelPath;
        var processor = factory.CreateBuilder().WithLanguage(language).WithNoContext()
            .WithThreads(Threads).Build();
        try
        {
            var segments = new List<string>();
            await foreach (var segment in processor.ProcessAsync(samples, cancellation)) segments.Add(segment.Text);
            return WhisperText.Join(segments);
        }
        catch (Exception) when (cancellation.IsCancellationRequested)
        {
            throw new OperationCanceledException(cancellation); // A cancelled run reports a cancellation, not a failure.
        }
        finally
        {
            // A cancelled run can still hold the processor until the native abort lands. The synchronous
            // Dispose throws in that window, so dispose asynchronously and stop waiting after 5 s.
            try { await processor.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5)); } catch { processorMayLinger = true; }
        }
    }, cancellation);
    public void Dispose()
    {
        factory?.Dispose(); factory = null;
        ReleaseParakeet();
    }
}

/// Parakeet could not be created for its folder. The dictation falls back to Whisper.
internal sealed class ParakeetLoadException(Exception inner) : Exception("Parakeet did not load.", inner);
