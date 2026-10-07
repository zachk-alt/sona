using System.Text.Json;
using System.Text.Json.Nodes;

namespace Sona.Core;

public sealed record Shortcut(int VirtualKey = 0x20, uint Modifiers = 0x0002 | 0x0001)
{
    public bool IsModifierOnly => Modifiers == 0 && VirtualKey is 0xA0 or 0xA1 or 0xA2 or 0xA3 or 0xA4 or 0xA5;
    public bool IsValid => VirtualKey is >= 8 and <= 254 && VirtualKey != 0x7B && (Modifiers & ~15u) == 0
        && (VirtualKey is not (0x5B or 0x5C or 0x10 or 0x11 or 0x12))
        && (!(VirtualKey is >= 0xA0 and <= 0xA5) || Modifiers == 0);
}

public sealed record AppSettings
{
    public int Version { get; init; } = 1;
    public bool SetupComplete { get; init; }
    public Shortcut Shortcut { get; init; } = new();
    public bool CleanupEnabled { get; init; } = true;
    public bool AutoAddToDictionary { get; init; }
    public string Language { get; init; } = "auto";
    public string? MicrophoneId { get; init; }
    public string? NodePath { get; init; }
    public bool StartAtLogin { get; init; }
    public int MaximumRecordingSeconds { get; init; } = 120;

    public AppSettings Validate() => this with
    {
        Shortcut = Shortcut is { IsValid: true } ? Shortcut : new Shortcut(),
        MaximumRecordingSeconds = Math.Clamp(MaximumRecordingSeconds, 5, 300),
        Language = string.IsNullOrWhiteSpace(Language) ? "auto" : Language.Trim(),
        NodePath = string.IsNullOrWhiteSpace(NodePath) ? null : NodePath.Trim()
    };
}

public static class SettingsStore
{
    public static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    public static AppSettings Load(string path)
    {
        try
        {
            var document = JsonNode.Parse(File.ReadAllText(path))?.AsObject() ?? new();
            T Read<T>(string name, T fallback)
            {
                try { return document[name] == null ? fallback : document[name]!.Deserialize<T>(JsonOptions)!; }
                catch (Exception e) when (e is JsonException or InvalidOperationException or NotSupportedException) { return fallback; }
            }
            // Legacy commandShortcut and assistant fields are unowned data. Never parse or activate them.
            var defaults = new AppSettings();
            return (defaults with
            {
                Version = Read("version", defaults.Version), SetupComplete = Read("setupComplete", false),
                Shortcut = Read("shortcut", defaults.Shortcut),
                AutoAddToDictionary = Read("autoAddToDictionary", false), CleanupEnabled = Read("cleanupEnabled", true),
                Language = Read("language", "auto"), MicrophoneId = Read<string?>("microphoneId", null), NodePath = Read<string?>("nodePath", null),
                StartAtLogin = Read("startAtLogin", false), MaximumRecordingSeconds = Read("maximumRecordingSeconds", 120)
            }).Validate();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException or InvalidOperationException) { return new(); }
    }
    public static JsonObject MergeDocument(string path, AppSettings settings)
    {
        JsonObject existing;
        try { existing = File.Exists(path) ? JsonNode.Parse(File.ReadAllText(path))?.AsObject() ?? throw new InvalidDataException("Settings must be an object.") : new(); }
        catch (Exception e) when (e is JsonException or InvalidOperationException) { throw new InvalidDataException("Existing settings are malformed. Correct them before saving.", e); }
        var owned = JsonSerializer.SerializeToNode(settings.Validate(), JsonOptions)!.AsObject();
        foreach (var pair in owned) existing[pair.Key] = pair.Value?.DeepClone();
        return existing;
    }
    public static void Save(string path, AppSettings settings) => FeatureConfig.WriteAtomic(path, MergeDocument(path, settings));

}

// Only a boolean chord marker is retained, never the identity of another key.
public sealed class ModifierTap
{
    private long? pressedAt;
    private bool chordUsed;
    public void Down(long milliseconds, bool otherModifierHeld)
    {
        if (pressedAt.HasValue) return;
        pressedAt = milliseconds;
        chordUsed = otherModifierHeld;
    }
    public void OtherKeyDown() { if (pressedAt.HasValue) chordUsed = true; }
    public bool Up(long milliseconds)
    {
        bool tap = pressedAt is long start && !chordUsed && milliseconds - start is >= 0 and <= 650;
        Reset();
        return tap;
    }
    public void Reset() { pressedAt = null; chordUsed = false; }
}

public static class ShortcutPolicy
{
    public static bool RightAltCommandAllowed(uint keyboardLayout) => keyboardLayout == 0x04090409;
}

public static class InsertionPolicy
{
    public static bool MayPaste(nint expectedWindow, uint expectedProcess, nint expectedFocus,
        nint currentWindow, uint currentProcess, nint currentFocus, bool isPassword, bool automationMatches) =>
        expectedWindow != 0 && expectedProcess != 0 && expectedFocus != 0 && !isPassword && automationMatches &&
        expectedWindow == currentWindow && expectedProcess == currentProcess && expectedFocus == currentFocus;

    public static bool MayRestoreClipboard(uint ourSequence, uint currentSequence) => ourSequence != 0 && ourSequence == currentSequence;
}
