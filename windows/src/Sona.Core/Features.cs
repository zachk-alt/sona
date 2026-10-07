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
        if (source.Any(v => v == null || v.Trigger == null || v.Expansion == null)) throw new InvalidDataException("Snippet fields must be strings.");
        var result = source.Select(v => new Snippet(v.Trigger.Trim(), v.Expansion)).ToArray();
        if (result.Length > 128 || result.Any(v => string.IsNullOrWhiteSpace(v.Trigger) || v.Trigger.EnumerateRunes().Count() > 120 || v.Trigger.Any(c => IsControl(c) || c is '\u2028' or '\u2029') || string.IsNullOrWhiteSpace(v.Expansion) || Encoding.UTF8.GetByteCount(v.Expansion) > 8192 || v.Expansion.Any(c => IsControl(c) && c is not ('\t' or '\n' or '\r'))) || result.Sum(v => Encoding.UTF8.GetByteCount(v.Expansion)) > 65536)
            throw new InvalidDataException("Each snippet needs a trigger up to 120 characters and an expansion up to 8 KB; at most 128 snippets and 64 KB of expansions.");
        if (result.Select(v => v.Trigger).Distinct(StringComparer.OrdinalIgnoreCase).Count() != result.Length) throw new InvalidDataException("Snippet triggers must be unique.");
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
    public static string Dictate(string raw, bool cleanup) => JsonSerializer.Serialize(new { version = 1, operation = "dictate", transcript = raw, mode = "prose", cleanupEnabled = cleanup });
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
