using System.Text;
using System.Text.Json;

namespace Sona.Core;

public sealed record ChatMessage(string Role, string Content);
public sealed record AssistantApp(string Id, string Label);
public sealed record AssistantAction(string Type, double X = 0, double Y = 0, string? Text = null, string? Key = null, string? Direction = null, int Amount = 1, string? AppId = null, string? Url = null, bool RequiresConfirmation = false, int Milliseconds = 0);
public sealed class TemporaryChat
{
    private readonly List<ChatMessage> messages = [];
    public ChatMessage[] Messages => messages.ToArray();
    public void Add(string role, string content)
    {
        if (role is not ("user" or "assistant") || Encoding.UTF8.GetByteCount(content) > 16384) throw new InvalidDataException("Temporary message exceeds its bound.");
        messages.Add(new(role, content));
        while (messages.Count > 16 || messages.Sum(m => Encoding.UTF8.GetByteCount(m.Content)) > 32768) messages.RemoveAt(0);
    }
    public void Clear() => messages.Clear();
}
public sealed class ActionBudget(Func<long> milliseconds)
{
    private readonly long deadline = milliseconds() + 180000;
    private int dispatched;
    public bool Active => milliseconds() < deadline;
    public bool TryDispatch() => Active && dispatched++ < 12;
}
public static class AssistantActionPolicy
{
    public static readonly string[] Keys = ["enter", "shift+enter", "tab", "escape", "backspace", "delete", "left", "right", "up", "down", "cmd+a", "cmd+z"];
    public static bool Terminal(string process, string description) => new[] { "cmd", "powershell", "pwsh", "WindowsTerminal", "OpenConsole", "ConEmu", "ConEmu64", "mintty", "wezterm-gui", "alacritty", "Warp" }.Contains(process, StringComparer.OrdinalIgnoreCase) || System.Text.RegularExpressions.Regex.IsMatch(description, @"\b(terminal|console|password)\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant);
    public static bool Consequential(string? label) => label != null && System.Text.RegularExpressions.Regex.IsMatch(label, @"\b(send|delete|remove|pay|buy|publish|submit|install|allow|grant|share|purchase|erase|transfer)\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant);
    public static bool Confirm(AssistantAction action, string? nativeLabel = null) => action.RequiresConfirmation || action.Type == "key" && action.Key is "enter" or "shift+enter" || action.Type == "click" && Consequential(nativeLabel);
    public static AssistantAction Parse(JsonElement value)
    {
        string type = value.GetProperty("type").GetString() ?? throw new InvalidDataException();
        bool confirm = value.TryGetProperty("requiresConfirmation", out var c) && c.GetBoolean();
        string Text(string name, int maximum) { string? text = value.GetProperty(name).GetString(); if (text == null || Encoding.UTF8.GetByteCount(text) > maximum || text.Any(c => (c <= 31 || c is >= '\u007F' and <= '\u009F') && c is not ('\r' or '\n' or '\t'))) throw new InvalidDataException(); return text; }
        int WaitMilliseconds()
        {
            if (!value.TryGetProperty("milliseconds", out var duration) || duration.ValueKind != JsonValueKind.Number || !duration.TryGetInt32(out int milliseconds)
                || !AssistantWait.ValidDuration(milliseconds) || value.EnumerateObject().Any(field => field.Name is not ("type" or "milliseconds" or "requiresConfirmation"))) throw new InvalidDataException();
            return milliseconds;
        }
        var result = type switch
        {
            "click" => new AssistantAction(type, X: value.GetProperty("x").GetDouble(), Y: value.GetProperty("y").GetDouble(), RequiresConfirmation: confirm),
            "type" => new AssistantAction(type, Text: Text("text", 16384), RequiresConfirmation: confirm),
            "key" => new AssistantAction(type, Key: Text("key", 32), RequiresConfirmation: confirm),
            "scroll" => new AssistantAction(type, Direction: Text("direction", 8), Amount: value.GetProperty("amount").GetInt32(), RequiresConfirmation: confirm),
            "open_app" => new AssistantAction(type, AppId: Text("appId", 200), RequiresConfirmation: confirm),
            "open_url" => new AssistantAction(type, Url: Text("url", 2048), RequiresConfirmation: confirm),
            "wait" => new AssistantAction(type, RequiresConfirmation: confirm, Milliseconds: WaitMilliseconds()),
            _ => throw new InvalidDataException()
        };
        bool valid = type switch
        {
            "click" => double.IsFinite(result.X) && double.IsFinite(result.Y) && result.X is >= 0 and <= 1 && result.Y is >= 0 and <= 1,
            "key" => Keys.Contains(result.Key),
            "scroll" => result.Amount is >= 1 and <= 5 && result.Direction is "up" or "down",
            "type" => !string.IsNullOrEmpty(result.Text),
            "open_app" => !string.IsNullOrWhiteSpace(result.AppId),
            "open_url" => Uri.TryCreate(result.Url, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" && string.IsNullOrEmpty(uri.UserInfo),
            "wait" => AssistantWait.ValidDuration(result.Milliseconds),
            _ => false
        };
        if (!valid) throw new InvalidDataException();
        return result;
    }
}

public static class AssistantWait
{
    public static bool ValidDuration(int milliseconds) => milliseconds is >= 250 and <= 1500;
    // The native caller supplies its existing target-identity guard and linked
    // cancellation token. No input or foreground transition occurs during a wait.
    public static async Task<bool> RunAsync(int milliseconds, Func<bool> targetIsCurrent, CancellationToken cancellation)
    {
        if (!ValidDuration(milliseconds)) throw new InvalidDataException("Assistant wait duration is outside its bound.");
        cancellation.ThrowIfCancellationRequested();
        if (!targetIsCurrent()) return false;
        await Task.Delay(milliseconds, cancellation);
        cancellation.ThrowIfCancellationRequested();
        return targetIsCurrent();
    }
}

public static class BrowserTargetPolicy
{
    // Native running-process metadata only. The model never supplies an executable.
    public static bool IsBrowser(string name) => name.ToLowerInvariant() is "chrome" or "msedge" or "firefox" or "brave";
    public static bool ExecutableMatches(string name, string path)
    {
        string filename = path.Replace('\\', '/').Split('/').Last();
        return IsBrowser(name) && filename.Equals(name + ".exe", StringComparison.OrdinalIgnoreCase);
    }
}

// A bounded handoff requires a stable exact native window and focused child.
public sealed class WindowSettle
{
    private readonly long began;
    private long stableSince;
    private (long Window, uint Process, long Focus, int Left, int Top, int Right, int Bottom)? previous;
    public WindowSettle(long milliseconds) { began = stableSince = milliseconds; }
    public bool Expired(long milliseconds) => milliseconds - began >= 4000;
    public bool Observe(long milliseconds, long window, uint process, long focus, int left, int top, int right, int bottom)
    {
        if (Expired(milliseconds) || window == 0 || process == 0 || focus == 0 || right <= left || bottom <= top) { previous = null; stableSince = milliseconds; return false; }
        var value = (window, process, focus, left, top, right, bottom);
        if (previous != value) { previous = value; stableSince = milliseconds; return false; }
        return milliseconds - began >= 750 && milliseconds - stableSince >= 500;
    }
}
