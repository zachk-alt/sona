using System.Text.Json;

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
        try { return (JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), JsonOptions) ?? new()).Validate(); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }
    public static void Save(string path, AppSettings settings)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(settings.Validate(), JsonOptions));
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
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

public static class InsertionPolicy
{
    public static bool MayPaste(nint expectedWindow, uint expectedProcess, nint expectedFocus,
        nint currentWindow, uint currentProcess, nint currentFocus, bool isPassword, bool automationMatches) =>
        expectedWindow != 0 && expectedProcess != 0 && expectedFocus != 0 && !isPassword && automationMatches &&
        expectedWindow == currentWindow && expectedProcess == currentProcess && expectedFocus == currentFocus;

    public static bool MayRestoreClipboard(uint ourSequence, uint currentSequence) => ourSequence != 0 && ourSequence == currentSequence;
}
