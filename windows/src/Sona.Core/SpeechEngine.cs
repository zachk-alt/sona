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

/// Whisper's segments joined into one transcript. whisper.cpp models can emit a whole segment that is only an
/// annotation, such as [BLANK_AUDIO] or (music), for audio with no words; it is dropped so it is never typed.
/// Brackets inside spoken text are kept.
public static class WhisperText
{
    private static readonly System.Text.RegularExpressions.Regex Annotation =
        new(@"^\s*(?:(?:\[[^\[\]]*\]|\([^()]*\))\s*)+$", System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    public static bool IsAnnotation(string segment) => Annotation.IsMatch(segment);

    public static string Join(IEnumerable<string> segments)
    {
        var text = new System.Text.StringBuilder();
        foreach (var segment in segments) if (!IsAnnotation(segment)) text.Append(segment);
        return text.ToString().Trim();
    }
}

/// Parakeet TDT 0.6B v2 text as the user should see it. The model's "$" token carries no word-start marker, so every
/// dollar amount came out joined to the word before it ("the price range is$20,000 to$40,000": 9 of 9 on the
/// 2026-11-05 bench). A "$" right after a letter or a comma, colon or semicolon and right before a digit gets its space back.
public static class ParakeetText
{
    private static readonly System.Text.RegularExpressions.Regex GluedDollar =
        new(@"(?<=[\p{L},;:])\$(?=\d)", System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    public static string Tidy(string text) => GluedDollar.Replace(text, " $");
}
