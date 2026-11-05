namespace Sona.Core;

public enum SpeechEngine { Parakeet, Whisper }

/// Which local engine a dictation runs on, and when it falls back.
/// English runs on Parakeet once its files are verified; Whisper is the backup and the engine for "auto" and every other language.
public static class SpeechEngines
{
    /// Fixed log codes. The log never holds dictated or transcript text.
    public const string ParakeetLoadFailed = "parakeet_load_failed";
    public const string ParakeetDecodeFailed = "parakeet_decode_failed";
    public const string ParakeetDownloadFailed = "parakeet_download_failed";
    public const string ParakeetTimedOut = "parakeet_timed_out";

    /// The engine the language prefers when every model is in place.
    public static SpeechEngine Preferred(string? language) => SpeechModels.IsEnglish(language) ? SpeechEngine.Parakeet : SpeechEngine.Whisper;

    /// The engine a dictation starts on. Until Parakeet is verified (or after it is marked failed), English stays on Whisper.
    public static SpeechEngine ForDictation(string? language, bool parakeetVerified) =>
        Preferred(language) == SpeechEngine.Parakeet && parakeetVerified ? SpeechEngine.Parakeet : SpeechEngine.Whisper;

    /// After Parakeet failed on a dictation: that dictation runs on Whisper, unless the user cancelled it.
    public static bool FallBackToWhisper(Exception error, bool cancelled) => !cancelled && error is not OperationCanceledException;
}

/// Tracks Parakeet failures for one process. A model folder that failed to load is not tried again until Sona restarts,
/// so a broken install does not pay a load attempt on every dictation. A failed decode drops the loaded recognizer and
/// retries a fresh load next time; after MaximumDecodeFailures failures in a row the folder is left to Whisper too.
public sealed class ParakeetHealth
{
    public const int MaximumDecodeFailures = 3;
    private readonly HashSet<string> failedFolders = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, int> decodeFailures = new(StringComparer.OrdinalIgnoreCase);

    public bool ShouldTry(string folder) { lock (failedFolders) return !failedFolders.Contains(folder); }

    public void LoadFailed(string folder) { lock (failedFolders) failedFolders.Add(folder); }

    public void DecodeFailed(string folder)
    {
        lock (failedFolders)
        {
            int count = decodeFailures.GetValueOrDefault(folder) + 1;
            decodeFailures[folder] = count;
            if (count >= MaximumDecodeFailures) failedFolders.Add(folder);
        }
    }

    public void Succeeded(string folder) { lock (failedFolders) decodeFailures.Remove(folder); }
}
