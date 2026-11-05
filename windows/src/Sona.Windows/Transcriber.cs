using System.Text;
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
    // load, decode and release; a cancelled dictation stops waiting while the decode it started finishes on its own.
    private readonly SemaphoreSlim parakeetGate = new(1, 1);
    private ParakeetRecognizer? parakeet;
    private readonly ParakeetHealth parakeetHealth = new();
    public ParakeetHealth Health => parakeetHealth;

    /// A WAV recording, through the one conversion both engines share.
    public Task<Transcript> TranscribeAsync(byte[] recording, SpeechRoute route, CancellationToken cancellation) =>
        TranscribeAsync(SpeechAudio.Mono16k(recording), route, cancellation);
    public Task<string> TranscribeAsync(byte[] recording, string modelPath, string language, CancellationToken cancellation) =>
        TranscribeAsync(SpeechAudio.Mono16k(recording), modelPath, language, cancellation);

    /// Both engines hear the same 16 kHz mono samples (SpeechAudio.Mono16k).
    /// Parakeet first when the route has it and it has not failed; on a load or decode failure that dictation runs on
    /// Whisper. Failures are logged as fixed codes with the exception type only, never text.
    public async Task<Transcript> TranscribeAsync(float[] samples, SpeechRoute route, CancellationToken cancellation)
    {
        if (route.ParakeetFolder != null && parakeetHealth.ShouldTry(route.ParakeetFolder))
        {
            try { return new(await TranscribeParakeetAsync(samples, route.ParakeetFolder, cancellation), SpeechEngine.Parakeet); }
            catch (Exception e) when (SpeechEngines.FallBackToWhisper(e, cancellation.IsCancellationRequested))
            {
                App.Log(e is ParakeetLoadException ? SpeechEngines.ParakeetLoadFailed : SpeechEngines.ParakeetDecodeFailed, e.InnerException ?? e);
            }
        }
        return new(await TranscribeAsync(samples, route.WhisperModelPath, route.WhisperLanguage, cancellation), SpeechEngine.Whisper);
    }

    /// Loads Parakeet ahead of the first dictation so that dictation does not wait for it. A failure is logged and
    /// marks the folder failed, so English keeps running on Whisper.
    public Task PreloadParakeetAsync(string folder) => Task.Run(async () =>
    {
        if (!parakeetHealth.ShouldTry(folder)) return;
        await parakeetGate.WaitAsync();
        try { Load(folder); }
        catch (ParakeetLoadException e) { App.Log(SpeechEngines.ParakeetLoadFailed, e.InnerException ?? e); }
        finally { parakeetGate.Release(); }
    });

    /// Frees the loaded Parakeet model, for a switch away from English. Skipped while a decode still runs.
    public void ReleaseParakeet()
    {
        if (!parakeetGate.Wait(0)) return;
        try { parakeet?.Dispose(); parakeet = null; }
        finally { parakeetGate.Release(); }
    }

    private async Task<string> TranscribeParakeetAsync(float[] samples, string folder, CancellationToken cancellation)
    {
        await parakeetGate.WaitAsync(cancellation);
        var decode = Task.Run(() =>
        {
            try
            {
                var engine = Load(folder);
                try { string text = engine.Transcribe(samples); parakeetHealth.Succeeded(folder); return text; }
                catch (Exception)
                {
                    // The recognizer may be in a bad state: drop it, reload on the next dictation.
                    parakeetHealth.DecodeFailed(folder);
                    try { engine.Dispose(); } catch { }
                    parakeet = null;
                    throw;
                }
            }
            finally { parakeetGate.Release(); }
        }, CancellationToken.None);
        return await decode.WaitAsync(cancellation);
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
            var text = new StringBuilder();
            await foreach (var segment in processor.ProcessAsync(samples, cancellation)) text.Append(segment.Text);
            return text.ToString().Trim();
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
