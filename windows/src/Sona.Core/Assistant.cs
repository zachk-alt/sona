using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Sona.Core;

public sealed record AssistantOptions(string Provider = "inherit", string Model = "default", string Effort = "default", int TimeoutMs = 120000)
{
    public static AssistantOptions Read(JsonNode? node)
    {
        if (node == null) return new();
        if (node is not JsonObject) throw new InvalidDataException("Assistant settings must be an object.");
        try
        {
            var value = new AssistantOptions(node["provider"]?.GetValue<string>() ?? "inherit", node["model"]?.GetValue<string>() ?? "default", node["effort"]?.GetValue<string>() ?? "default", node["timeoutMs"]?.GetValue<int>() ?? 120000);
            if (new[] { value.Provider, value.Model, value.Effort }.Any(v => string.IsNullOrWhiteSpace(v) || v.Length > 200 || v.Any(char.IsControl)) || value.TimeoutMs is < 250 or > 180000) throw new InvalidDataException("Assistant settings are invalid.");
            return value;
        }
        catch (Exception e) when (e is InvalidOperationException or FormatException) { throw new InvalidDataException("Assistant settings are invalid.", e); }
    }
    public JsonObject ToJson() => new() { ["provider"] = Provider, ["model"] = Model, ["effort"] = Effort, ["timeoutMs"] = TimeoutMs };
}
public sealed record AssistantModel(string Id, string Label, bool Vision, string[] Efforts, string DefaultEffort, string[] Operations)
{ public override string ToString() => Label + (Vision ? "" : " (text only)"); }
public sealed record AssistantProvider(string Id, string Label, bool Available, string? Reason, string CatalogSource, AssistantModel[] Models)
{ public override string ToString() => Label + (Available ? "" : " (unavailable)"); }
public sealed record AssistantCatalog(AssistantOptions Selected, AssistantProvider[] Providers);
public sealed record AssistantReply(string Status, string? Kind = null, string? Text = null, string FailureCode = "unavailable")
{
    // Retain only fixed categories. Unknown reason strings and error bodies must
    // never enter the answer panel, record diagnostics, or local logs.
    public static AssistantReply Failed(string? reason) => new("error", FailureCode: reason switch
    {
        "timeout" or "blender_timeout" => "timeout",
        "cancelled" => "cancelled",
        "assistant_model_unavailable" or "unexpected_model" or "model_changed" => "model_unavailable",
        "assistant_effort_unavailable" => "effort_unavailable",
        "assistant_vision_unavailable" => "vision_unavailable",
        "cli_not_found" or "no_supported_cli" or "codex_native_not_found" => "cli_missing",
        "ai_disabled" => "disabled",
        "assistant_provider_not_reviewed" or "local_history_not_allowed" => "connection_unsupported",
        "invalid_assistant_response" or "incomplete_response" or "invalid_response" or "invalid_assistant_actions" or "response_too_large" => "invalid_response",
        "images_too_large" or "invalid_image" or "invalid_images" or "input_too_large" or "assistant_history_too_large" => "request_rejected",
        "authentication_failed" => "authentication_failed",
        "provider_access_denied" => "access_denied",
        "billing_error" => "billing_error",
        "rate_limited" => "rate_limited",
        "provider_request_rejected" => "provider_rejected",
        "provider_unavailable" => "provider_unavailable",
        "provider_error" or "cli_failed" or "cli_closed" or "provider_tool_or_error" or "launch_failed" or "cli_launch_failed" or "cli_stdin_failed" => "connection_failed",
        _ => "unavailable"
    });
    public string FailureMessage => FailureCode switch
    {
        "timeout" => "The selected AI took too long to respond to this step.",
        "cancelled" => "This step was cancelled.",
        "model_unavailable" => "The selected Assistant model is unavailable. Check the model in Sona's Settings.",
        "effort_unavailable" => "The selected reasoning level is unavailable for this model. Check the Assistant settings.",
        "vision_unavailable" => "The selected Assistant model does not support screen images. Choose an image-capable model.",
        "cli_missing" => "Sona could not find the CLI for the selected Assistant connection.",
        "disabled" => "The Assistant AI connection is turned off.",
        "connection_unsupported" => "The selected connection does not support Sona's Assistant requests.",
        "invalid_response" => "The AI returned an incomplete or unusable response for this step.",
        "request_rejected" => "The screen request could not be sent in its current form.",
        "authentication_failed" => "The AI connection needs you to sign in again through its CLI.",
        "access_denied" => "The AI account does not allow this request. Check access in the selected CLI.",
        "billing_error" => "The AI provider reported a billing problem. Check the account used by its CLI.",
        "rate_limited" => "The AI provider has reached a usage or rate limit. Try again when access resets.",
        "provider_rejected" => "The AI provider rejected this request. Try a fresh Option request; if it repeats, check the selected model.",
        "provider_unavailable" => "The AI provider is temporarily unavailable. Try the Option request again shortly.",
        "connection_failed" => "The AI connection failed while processing this step.",
        _ => "The AI connection could not finish this step."
    };
}
public sealed record WindowImage(string MimeType, string DataBase64);

public static class AssistantProtocol
{
    public const int MaximumImageBytes = 4 * 1024 * 1024;
    public static string Request(string instruction, WindowImage image, AssistantOptions options, string appName, string windowTitle, ChatMessage[]? messages = null)
        => JsonSerializer.Serialize(new { version = 1, operation = "assistant", intent = "screen_ask", instruction, images = new[] { new { mimeType = image.MimeType, dataBase64 = image.DataBase64 } }, context = new { appName, windowTitle }, messages = (messages ?? []).Select(m => new { role = m.Role, content = m.Content }), options = new { provider = options.Provider, model = options.Model, effort = options.Effort } });
    public static string Rewrite(string selection, string instruction, AssistantOptions options)
        => JsonSerializer.Serialize(new { version = 1, operation = "rewrite", profile = "assistant", selection, instruction, options = new { provider = options.Provider, model = options.Model, effort = options.Effort } });
    public static AssistantCatalog? Catalog(ProcessResult result)
    {
        if (!result.Success || result.Output.Length > 131072) return null;
        try
        {
            using var document = JsonDocument.Parse(result.Output); var root = document.RootElement;
            if (root.GetProperty("version").GetInt32() != 1 || root.GetProperty("operation").GetString() != "catalog" || root.GetProperty("status").GetString() != "ok") return null;
            var selected = AssistantOptions.Read(JsonNode.Parse(root.GetProperty("selected").GetRawText()));
            var providers = root.GetProperty("providers").EnumerateArray().Select(p => new AssistantProvider(
                Required(p, "id"), Required(p, "label"), p.GetProperty("available").GetBoolean(), p.TryGetProperty("reason", out var reason) ? reason.GetString() : null, Required(p, "catalogSource"),
                p.GetProperty("models").EnumerateArray().Select(m => new AssistantModel(Required(m, "id"), Required(m, "label"), m.GetProperty("vision").GetBoolean(), Strings(m, "efforts"), Required(m, "defaultEffort"), Strings(m, "operations"))).ToArray())).ToArray();
            if (providers.Length > 64 || providers.Select(p => p.Id).Distinct().Count() != providers.Length || providers.Any(p => p.Models.Length > 256 || p.Models.Select(m => m.Id).Distinct().Count() != p.Models.Length || p.Models.Any(m => m.Efforts.Length > 32))) return null;
            return new(selected, providers);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or InvalidDataException) { return null; }
    }
    public static AssistantReply Parse(ProcessResult result)
    {
        if (!result.Success) return AssistantReply.Failed(result.Failure);
        if (Encoding.UTF8.GetByteCount(result.Output) > 131072) return new("error");
        try
        {
            using var document = JsonDocument.Parse(result.Output); var root = document.RootElement;
            if (root.GetProperty("version").GetInt32() != 1 || root.GetProperty("operation").GetString() != "assistant") return new("error");
            string? status = root.GetProperty("status").GetString();
            if (status != "ok") return status == "error"
                ? AssistantReply.Failed(root.TryGetProperty("reason", out var reason) && reason.ValueKind == JsonValueKind.String ? reason.GetString() : null)
                : new("error");
            // A stale bridge or mixed answer/action response cannot escape into the UI.
            if (root.EnumerateObject().Any(field => field.Name is not ("version" or "operation" or "status" or "kind" or "text"))) return AssistantReply.Failed("invalid_assistant_response");
            string kind = Required(root, "kind"), text = root.GetProperty("text").GetString()!;
            if (kind != "answer" || string.IsNullOrWhiteSpace(text) || Encoding.UTF8.GetByteCount(text) > 65536 || text.Any(c => (c <= 31 || c is >= '\u007F' and <= '\u009F') && c is not ('\r' or '\n' or '\t'))) return AssistantReply.Failed("invalid_assistant_response");
            return new("ok", "answer", text);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or InvalidDataException) { return new("error"); }
    }
    private static string Required(JsonElement value, string key)
    {
        string? text = value.GetProperty(key).GetString();
        if (string.IsNullOrWhiteSpace(text) || text.Length > 500 || text.Any(char.IsControl)) throw new InvalidDataException();
        return text;
    }
    private static string[] Strings(JsonElement value, string key) => value.GetProperty(key).EnumerateArray().Select(s => s.GetString() is string text && text.Length is > 0 and < 200 && !text.Any(char.IsControl) ? text : throw new InvalidDataException()).ToArray();
}

public static class WindowCapturePolicy
{
    public static bool Allowed(long expectedWindow, uint expectedProcess, long currentWindow, uint currentProcess, uint ownProcess, bool isWindow, bool minimized, bool cloaked, bool affinityKnown, uint affinity, int width, int height)
        => expectedWindow != 0 && expectedProcess != 0 && expectedProcess != ownProcess && expectedWindow == currentWindow && expectedProcess == currentProcess && isWindow && !minimized && !cloaked && affinityKnown && affinity == 0 && width is > 0 and <= 8192 && height is > 0 and <= 8192 && (long)width * height <= 33554432;
}
