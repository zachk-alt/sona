using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Sona.Core;

public enum RecordingMode { Dictate, Rewrite, Assistant }
public sealed record Snippet(string Trigger, string Expansion);
public sealed record WordCorrection(string Original, string Replacement);
public sealed record BridgeReply(string Status, string? Text = null, Snippet[]? Snippets = null, string? Reason = null);

public static class FeatureConfig
{
    private static bool IsControl(char c) => c <= 0x1F || c is >= '\u007F' and <= '\u009F';
    public static string[] Vocabulary(IEnumerable<string> values)
    {
        var source = values.ToArray();
        if (source.Any(v => v == null)) throw new InvalidDataException("Vocabulary entries must be strings.");
        var result = source.Select(v => v.Trim()).Where(v => v.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (result.Length > 256 || result.Any(v => v.Length > 100 || v.Any(IsControl))) throw new InvalidDataException("Vocabulary allows 256 entries, each at most 100 characters without control characters.");
        return result;
    }
    public static Snippet[] Snippets(IEnumerable<Snippet> values)
    {
        var source = values.ToArray();
        if (source.Any(v => v == null || v.Trigger == null || v.Expansion == null)) throw new InvalidDataException("Each saved phrase needs a text trigger and text.");
        var result = source.Select(v => new Snippet(v.Trigger.Trim(), v.Expansion)).ToArray();
        if (result.Length > 128 || result.Any(v => string.IsNullOrWhiteSpace(v.Trigger) || v.Trigger.EnumerateRunes().Count() > 120 || v.Trigger.Any(c => IsControl(c) || c is '\u2028' or '\u2029') || string.IsNullOrWhiteSpace(v.Expansion) || Encoding.UTF8.GetByteCount(v.Expansion) > 8192 || v.Expansion.Any(c => IsControl(c) && c is not ('\t' or '\n' or '\r'))) || result.Sum(v => Encoding.UTF8.GetByteCount(v.Expansion)) > 65536)
            throw new InvalidDataException("Each saved phrase needs a trigger of 1 to 120 characters and text up to 8 KB. Keep it to 128 phrases and 64 KB of text in all.");
        if (result.Select(v => v.Trigger).Distinct(StringComparer.OrdinalIgnoreCase).Count() != result.Length) throw new InvalidDataException("Each saved phrase needs its own trigger.");
        return result;
    }
    public static void CommitDocuments(params (string Path, JsonObject Document)[] documents)
    {
        var staged = new List<(string Path, string Temporary, string? Original)>();
        int moved = 0;
        try
        {
            foreach (var item in documents)
            {
                string? old = File.Exists(item.Path) ? File.ReadAllText(item.Path) : null;
                if (old != null && JsonNode.Parse(old) is not JsonObject) throw new InvalidDataException("Existing configuration must be an object.");
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(item.Path))!);
                string temporary = item.Path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                staged.Add((item.Path, temporary, old));
                File.WriteAllText(temporary, item.Document.ToJsonString(SettingsStore.JsonOptions));
            }
            foreach (var item in staged) { File.Move(item.Temporary, item.Path, true); moved++; }
        }
        catch (Exception error)
        {
            bool rollbackFailed = false;
            for (int i = moved - 1; i >= 0; i--)
            {
                try
                {
                    var item = staged[i];
                    if (item.Original == null) File.Delete(item.Path);
                    else { File.WriteAllText(item.Temporary, item.Original); File.Move(item.Temporary, item.Path, true); }
                }
                catch { rollbackFailed = true; }
            }
            throw new InvalidDataException(rollbackFailed ? "Configuration save failed and restoration was incomplete. Review both settings files before continuing." : "Configuration save failed. Previous files were retained.", error);
        }
        finally { foreach (var item in staged) { try { if (File.Exists(item.Temporary)) File.Delete(item.Temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { } } }
    }
    public static void WriteAtomic(string path, JsonObject document)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temp, document.ToJsonString(SettingsStore.JsonOptions)); File.Move(temp, path, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}

public static class BridgeProtocol
{
    public static string Dictate(string raw, bool cleanup) => Dictate(raw, cleanup, CleanupMode.Prose);
    public static string Dictate(string raw, bool cleanup, CleanupMode mode) => JsonSerializer.Serialize(new { version = 1, operation = "dictate", transcript = raw, mode = mode == CleanupMode.Strict ? "strict" : "prose", cleanupEnabled = cleanup });
    public static string Rewrite(string selection, string instruction) => JsonSerializer.Serialize(new { version = 1, operation = "rewrite", selection, instruction });
    public static string Assist(string context) => JsonSerializer.Serialize(new { version = 1, operation = "snippet_assist", context });
    public static BridgeReply Parse(ProcessResult result, string operation, string? originalSelection = null, string? context = null)
    {
        if (!result.Success || Encoding.UTF8.GetByteCount(result.Output) > 131072) return new("error", Reason: "transport");
        try
        {
            using var json = JsonDocument.Parse(result.Output);
            var root = json.RootElement;
            if (root.GetProperty("version").GetInt32() != 1 || root.GetProperty("operation").GetString() != operation) return new("error", Reason: "protocol");
            string? status = root.GetProperty("status").GetString();
            if (status is not ("ok" or "fallback" or "error" or "needs_input")) return new("error", Reason: "protocol");
            string? text = root.TryGetProperty("text", out var value) ? value.GetString() : null;
            if (text != null && (Encoding.UTF8.GetByteCount(text) > 65536 || text.Any(c => (c <= 0x1F || c is >= '\u007F' and <= '\u009F') && c is not ('\r' or '\n' or '\t')))) return new("error", Reason: "invalid_text");
            if (operation == "rewrite" && (status != "ok" || string.IsNullOrWhiteSpace(text) || originalSelection == null || !SameOuterWhitespace(originalSelection, text))) return new("error", Reason: "rewrite_unavailable");
            if (operation == "dictate" && (status is not ("ok" or "fallback") || text == null)) return new("error", Reason: "dictation_unavailable");
            Snippet[]? snippets = null;
            if (operation == "snippet_assist" && status == "ok")
            {
                snippets = FeatureConfig.Snippets(root.GetProperty("snippets").EnumerateArray().Select(s => new Snippet(s.GetProperty("trigger").GetString()!, s.GetProperty("expansion").GetString()!)));
                if (context == null || snippets.Any(s => !context.Contains(s.Expansion, StringComparison.Ordinal))) return new("error", Reason: "proposal_not_in_context");
            }
            return new(status!, text, snippets);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or InvalidDataException or ArgumentException) { return new("error", Reason: "protocol"); }
    }
    public static string DictationText(ProcessResult result, string raw)
    {
        var reply = Parse(result, "dictate"); return reply.Status == "ok" ? reply.Text ?? raw : raw;
    }
    private static bool SameOuterWhitespace(string original, string result)
    {
        static (string Start, string End) Outer(string text)
        {
            bool Space(char c) => char.IsWhiteSpace(c) || c == '\uFEFF';
            int start = 0, end = text.Length;
            while (start < end && Space(text[start])) start++;
            while (end > start && Space(text[end - 1])) end--;
            return (text[..start], text[end..]);
        }
        bool Body(string text) => text.Any(c => !char.IsWhiteSpace(c) && c != '\uFEFF');
        return Body(original) && Body(result) && Outer(original) == Outer(result);
    }
}

/// AI cleanup time limits, matched to the Mac. The bridge stops a slow provider at ai.timeoutMs and returns the raw
/// transcript; the process around it gets that plus 2 s to report, at most 35 s (AppState.swift, BridgeOperations).
public static class CleanupTimeouts
{
    /// The Mac's ai.timeoutMs default (Config.swift), written when Settings saves a configuration without one.
    public const int DefaultMs = 12000;
    /// What the bridge itself uses when ai.timeoutMs is missing (cleanup.mjs), so the cap never undercuts it.
    public const int BridgeDefaultMs = 15000;

    /// 0.3.0 wrote 15000 into ai.json on every Settings save, so that value is the old default, not a choice.
    public const int OldWindowsDefaultMs = 15000;

    public static TimeSpan ProcessCap(int? timeoutMs) => TimeSpan.FromSeconds(Math.Min(35, Math.Max(1, (timeoutMs ?? BridgeDefaultMs) / 1000.0 + 2)));

    /// When Settings saves: a missing ai.timeoutMs, or 0.3.0's default, becomes the Mac's 12 s. Any other value is kept.
    public static void ApplyDefault(JsonObject ai)
    {
        var value = ai["timeoutMs"];
        bool oldDefault = value is JsonValue number && number.TryGetValue(out int ms) && ms == OldWindowsDefaultMs;
        if (value is null || oldDefault) ai["timeoutMs"] = DefaultMs;
    }

    /// ai.timeoutMs from an ai.json document; null when the document, the field or its integer is missing.
    public static int? Read(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try
        {
            using var document = JsonDocument.Parse(json);
            return document.RootElement.ValueKind == JsonValueKind.Object && document.RootElement.TryGetProperty("ai", out var ai) && ai.ValueKind == JsonValueKind.Object
                && ai.TryGetProperty("timeoutMs", out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out int ms) ? ms : null;
        }
        catch (JsonException) { return null; }
    }
}

/// Files Settings writes for the user to edit.
public static class SettingsTemplates
{
    /// What "Open AI configuration" creates when ai.json does not exist yet.
    public static readonly string AiConfiguration =
        $"{{\n  \"ai\": {{ \"provider\": \"auto\", \"model\": \"economy\", \"timeoutMs\": {CleanupTimeouts.DefaultMs} }},\n  \"vocabulary\": []\n}}\n";
}

public enum CleanupMode { Prose, Strict }

/// Code editors and terminals get the bridge's strict cleanup, because the text is probably a command or code, where
/// prose cleanup (capitals, punctuation, dropped fillers) breaks flags and identifiers. The Mac's strictModeBundleIDs
/// (Config.swift) as Windows process names, picked from the focused process when the dictation starts.
public static class CleanupModes
{
    public static readonly IReadOnlySet<string> StrictProcesses = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        // Terminals and shells.
        "WindowsTerminal", "OpenConsole", "conhost", "powershell", "pwsh", "cmd", "wezterm-gui", "alacritty", "Hyper", "Warp",
        // Code editors.
        "Code", "Code - Insiders", "Cursor", "devenv", "sublime_text", "Zed",
        // JetBrains IDEs and Android Studio.
        "idea64", "pycharm64", "webstorm64", "phpstorm64", "clion64", "rider64", "goland64", "rubymine64", "datagrip64",
        "rustrover64", "dataspell64", "aqua64", "studio64",
    };

    /// A process name with or without ".exe"; an unknown or unreadable process gets prose.
    public static CleanupMode ForProcess(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return CleanupMode.Prose;
        name = name.Trim();
        if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name = name[..^4];
        return StrictProcesses.Contains(name) ? CleanupMode.Strict : CleanupMode.Prose;
    }
}

// A commit is consumed before dispatch. An uncertain SendInput result never allows a retry.
public sealed class OneShotCommit
{
    private int dispatched;
    public bool TryBegin(bool validated) => validated && Interlocked.CompareExchange(ref dispatched, 1, 0) == 0;
}

public sealed class CorrectionLease(Func<long> milliseconds)
{
    private long deadline;
    private bool active;
    public void Start(bool enabled) { active = enabled; deadline = enabled ? milliseconds() + 15000 : 0; }
    public bool Active { get { if (active && milliseconds() >= deadline) active = false; return active; } }
    public void Stop() => active = false;
    public static WordCorrection? Candidate(string before, string after)
    {
        if (before == after || before.Length is 0 or > 4096 || after.Length is 0 or > 4096) return null;
        // Only one complete word may change. Insertions, deletions and new sentences are not learning.
        var a = System.Text.RegularExpressions.Regex.Matches(before, @"\p{L}[\p{L}\p{M}'’-]*");
        var b = System.Text.RegularExpressions.Regex.Matches(after, @"\p{L}[\p{L}\p{M}'’-]*");
        if (a.Count != b.Count) return null;
        WordCorrection? candidate = null;
        for (int i = 0; i < a.Count; i++)
        {
            if (a[i].Value == b[i].Value) continue;
            if (candidate != null || a[i].Length > 100 || b[i].Length > 100 || before[..a[i].Index] != after[..b[i].Index] || before[(a[i].Index + a[i].Length)..] != after[(b[i].Index + b[i].Length)..]) return null;
            candidate = new(a[i].Value, b[i].Value);
        }
        return candidate;
    }
}
