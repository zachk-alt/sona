using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Sona.Core;

// A dependency-free executable test harness. Throws/nonzero on failure.
Console.InputEncoding = new UTF8Encoding(false);
Console.OutputEncoding = new UTF8Encoding(false);
if (args.Length > 0 && args[0] == "--child")
{
    var text = await Console.In.ReadToEndAsync();
    switch (args[1])
    {
        case "echo": Console.Write(text); break;
        case "empty": break;
        case "fail": return 7;
        case "hang": await Task.Delay(TimeSpan.FromMinutes(2)); break;
        case "flood": Console.Write(new string('x', 200000)); await Task.Delay(10000); break;
    }
    return 0;
}
int tests = 0;
void Check(bool value, string name) { tests++; if (!value) throw new Exception("FAIL: " + name); Console.WriteLine("PASS " + name); }
var tap = new ModifierTap();
tap.Down(100, false); Check(tap.Up(180), "short modifier tap");
tap.Down(100, false); tap.Down(110, false); Check(tap.Up(200), "autorepeat does not restart modifier");
tap.Down(100, false); tap.OtherKeyDown(); Check(!tap.Up(200), "modifier chord is ignored");
tap.Down(100, true); Check(!tap.Up(200), "other held modifier blocks tap");
tap.Down(100, false); Check(!tap.Up(900), "hold is not a tap");
Check(!tap.Up(1000), "unpaired release ignored");
var conversation = new ConversationGesture();
Check(!conversation.Down(0, false, false) && conversation.Up(80) == ConversationGestureEvent.None, "closed panel retains normal shortcut path");
Check(conversation.Down(100, true, false) && conversation.Tick(300) == ConversationGestureEvent.None && conversation.Up(330) == ConversationGestureEvent.Dismiss, "answer quick tap dismisses without starting microphone");
conversation.Down(1000, true, false);
Check(conversation.Tick(1349) == ConversationGestureEvent.None && conversation.Tick(1350) == ConversationGestureEvent.BeginFollowUp, "answer hold starts at 350 milliseconds");
Check(conversation.Tick(1600) == ConversationGestureEvent.None && !conversation.Down(1700, true, false), "held shortcut autorepeat never starts another recording");
Check(conversation.Up(1800) == ConversationGestureEvent.FinishFollowUp && conversation.Up(1810) == ConversationGestureEvent.None, "follow-up release sends exactly once");
conversation.Down(2000, true, false); conversation.OtherKey();
Check(conversation.Tick(2500) == ConversationGestureEvent.None && conversation.Up(2600) == ConversationGestureEvent.None, "chord before threshold neither records nor dismisses answer");
conversation.Down(3000, true, true);
Check(conversation.Tick(3500) == ConversationGestureEvent.None && conversation.Up(3600) == ConversationGestureEvent.None, "already held unrelated key blocks follow-up");
conversation.Down(4000, true, false); conversation.Tick(4400);
Check(conversation.OtherKey() == ConversationGestureEvent.CancelFollowUp && conversation.OtherKey() == ConversationGestureEvent.None && conversation.Up(4500) == ConversationGestureEvent.None, "chord during follow-up cancels without submitting");
conversation.Down(5000, true, false);
Check(conversation.Up(5500) == ConversationGestureEvent.None && conversation.Tick(5600) == ConversationGestureEvent.None, "delayed timer cannot start microphone after release or dismiss long press");
conversation.Down(6000, true, false); conversation.Reset();
Check(conversation.Tick(6500) == ConversationGestureEvent.None && conversation.Up(6600) == ConversationGestureEvent.None, "disable resets pending hold");
Check(new Shortcut(0xA3, 0).IsValid && new Shortcut(0xA3, 0).IsModifierOnly, "right control selectable");
Check(!new Shortcut(0x7B, 0).IsValid, "F12 reserved");
Check(!new Shortcut(0x5B, 0).IsValid, "Windows key alone reserved");
Check(!new Shortcut(0xA3, 2).IsValid, "modifier cannot carry duplicate modifier mask");
Check(InsertionPolicy.MayPaste(1, 2, 3, 1, 2, 3, false, true), "same field accepted");
Check(!InsertionPolicy.MayPaste(1, 2, 3, 9, 2, 3, false, true), "changed app rejected");
Check(!InsertionPolicy.MayPaste(1, 2, 3, 1, 2, 8, false, true), "changed child field rejected");
Check(!InsertionPolicy.MayPaste(1, 2, 3, 1, 2, 3, true, true), "password rejected");
Check(!InsertionPolicy.MayPaste(1, 2, 3, 1, 2, 3, false, false), "changed UIA field rejected");
Check(!InsertionPolicy.MayPaste(1, 2, 3, 1, 9, 3, false, true), "recycled window process rejected");
Check(InsertionPolicy.MayRestoreClipboard(10, 10) && !InsertionPolicy.MayRestoreClipboard(10, 11), "clipboard user change preserved");
Check(ShortcutPolicy.RightAltCommandAllowed(0x04090409), "right Alt command supported layout");
Check(!ShortcutPolicy.RightAltCommandAllowed(0x04070407) && !ShortcutPolicy.RightAltCommandAllowed(0xF0010409), "AltGr and US-International are never reinterpreted");
Check(!new AppSettings().AutoAddToDictionary, "correction observation defaults off");
Check(typeof(AppSettings).GetProperties().Count(property => property.PropertyType == typeof(Shortcut)) == 1 && typeof(AppSettings).GetProperty("CommandShortcut") == null, "settings expose only the dictation shortcut");
Check(FeatureConfig.Vocabulary([" Sona ", "sona", "Actual Intelligence"]).SequenceEqual(new[] { "Sona", "Actual Intelligence" }), "dictionary trims and deduplicates");
bool Invalid(Action action) { try { action(); return false; } catch (InvalidDataException) { return true; } }
Check(Invalid(() => FeatureConfig.Snippets([new("a", "one"), new("A", "two")])), "duplicate snippet rejected");
Check(Invalid(() => FeatureConfig.Snippets([new("trigger", new string('x', 8193))])), "snippet byte bound");
Check(FeatureConfig.Snippets([new("my note", "First\nSecond\t✓")])[0].Expansion == "First\nSecond\t✓", "literal multiline snippet retained");
Check(Invalid(() => FeatureConfig.Snippets([new("x", "bad\u0001")])), "snippet control rejected");
Check(FeatureConfig.Snippets([new("signature", "First\r\nSecond")])[0].Expansion == "First\r\nSecond", "CRLF expansion preserved");
Check(Invalid(() => FeatureConfig.Snippets([new(null!, "text")])), "null trigger rejected");
Check(Invalid(() => FeatureConfig.Snippets([new("trigger", null!)])), "null expansion rejected");
Check(BridgeProtocol.Parse(new(true, "{\"version\":1,\"operation\":\"snippet_assist\",\"status\":\"ok\",\"snippets\":[{\"trigger\":null,\"expansion\":null}]}", null), "snippet_assist").Status == "error", "null proposal fields rejected without throwing");
const string originalText = "Exact raw transcript.\n✓";
ProcessResult Reply(string output) => new(true, output, null);
Check(BridgeProtocol.DictationText(new(false, "envelope", "timeout"), originalText) == originalText, "typed transport failure preserves original raw");
Check(BridgeProtocol.DictationText(Reply("not json"), originalText) == originalText, "malformed typed dictation preserves raw");
Check(BridgeProtocol.Parse(Reply("{\"version\":1,\"operation\":\"rewrite\",\"status\":\"fallback\",\"text\":\"bad\"}"), "rewrite").Text == null, "rewrite fallback never insertable");
Check(BridgeProtocol.Parse(Reply("{\"version\":1,\"operation\":\"rewrite\",\"status\":\"ok\",\"text\":\"Complete replacement\"}"), "rewrite", "Selected text").Text == "Complete replacement", "complete rewrite accepted");
Check(BridgeProtocol.Parse(Reply("{\"version\":1,\"operation\":\"dictate\",\"status\":\"ok\",\"text\":\"wrong operation\"}"), "rewrite").Text == null, "operation mismatch never insertable");
Check(BridgeProtocol.Parse(Reply("{\"version\":1,\"operation\":\"rewrite\",\"status\":\"ok\",\"text\":\"\"}"), "rewrite").Text == null, "empty rewrite never insertable");
Check(BridgeProtocol.DictationText(Reply("{\"version\":1,\"operation\":\"dictate\",\"status\":\"fallback\",\"text\":\"DIAGNOSTIC\"}"), originalText) == originalText, "fallback envelope cannot overwrite native raw");
Check(BridgeProtocol.Parse(Reply("{\"version\":1,\"operation\":\"rewrite\",\"status\":\"ok\",\"text\":\"replacement\"}"), "rewrite", "  selection ").Text == null, "rewrite outer whitespace mismatch rejected");
Check(BridgeProtocol.Parse(Reply("{\"version\":1,\"operation\":\"rewrite\",\"status\":\"ok\",\"text\":\"  replacement \"}"), "rewrite", "  selection ").Text == "  replacement ", "rewrite exact outer whitespace retained");
Check(BridgeProtocol.Parse(Reply("{\"version\":1,\"operation\":\"rewrite\",\"status\":\"ok\",\"text\":\"bad\\u0001\"}"), "rewrite", "selection").Text == null, "rewrite controls rejected");
Check(Invalid(() => FeatureConfig.Snippets([new("two\u2028lines", "value")])), "trigger Unicode line separator rejected");
Check(FeatureConfig.Vocabulary(["A\u200DB"])[0] == "A\u200DB", "vocabulary format characters allowed");
Check(BridgeProtocol.Parse(Reply("{\"version\":1,\"operation\":\"snippet_assist\",\"status\":\"ok\",\"snippets\":[{\"trigger\":\"signoff\",\"expansion\":\"Regards, Sam\"}]}"), "snippet_assist", context: "Use Regards, Sam as my signoff.").Status == "ok", "setup proposal must be present in supplied context");
Check(BridgeProtocol.Parse(Reply("{\"version\":1,\"operation\":\"snippet_assist\",\"status\":\"ok\",\"snippets\":[{\"trigger\":\"signoff\",\"expansion\":\"invented content\"}]}"), "snippet_assist", context: "Regards, Sam").Status == "error", "invented setup expansion rejected");
Check(BridgeProtocol.Parse(Reply("{\"version\":1,\"operation\":\"rewrite\",\"status\":\"ok\",\"text\":\"\\ufeff\"}"), "rewrite", "\uFEFFhello").Text == null, "FEFF-only rewrite body rejected");
var commit = new OneShotCommit();
Check(!commit.TryBegin(false), "unvalidated command does zero dispatches");
Check(commit.TryBegin(true) && !commit.TryBegin(true), "command dispatch consumed once including ambiguity");
long now = 100;
var lease = new CorrectionLease(() => now);
lease.Start(false); Check(!lease.Active, "disabled learning has no active lease");
lease.Start(true); now += 14999; Check(lease.Active, "learning inside 15-second window");
now++; Check(!lease.Active, "hard deadline does not renew");
now -= 5000; Check(!lease.Active, "expired lease cannot resurrect");
lease.Start(true); lease.Stop(); Check(!lease.Active, "off invalidates active lease immediately");
Check(CorrectionLease.Candidate("Meet Suna today.", "Meet Sona today.") == new WordCorrection("Suna", "Sona"), "one bounded word correction");
Check(CorrectionLease.Candidate("Meet Sona.", "Meet Sona. New text.") == null, "independently typed text not learned");
Check(CorrectionLease.Candidate("Meet Sona.", "") == null, "deleted span not learned");
Check(CorrectionLease.Candidate("Meet Suna soon.", "Visit Sona soon.") == null, "multiple replacements not learned");
Check(BrowserTargetPolicy.ExecutableMatches("chrome", @"C:\Program Files\Google\Chrome\Application\chrome.exe"), "current Chrome executable identity allowed");
Check(BrowserTargetPolicy.ExecutableMatches("MSEdge", @"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"), "current Edge executable identity allowed");
Check(!BrowserTargetPolicy.ExecutableMatches("chrome", @"C:\other.exe") && !BrowserTargetPolicy.ExecutableMatches("powershell", @"C:\powershell.exe"), "browser action refuses mismatched and arbitrary executables");
var settledWindow = new WindowSettle(100);
Check(!settledWindow.Observe(100, 1, 2, 3, 0, 0, 900, 700) && !settledWindow.Observe(500, 1, 2, 3, 0, 0, 900, 700) && settledWindow.Observe(850, 1, 2, 3, 0, 0, 900, 700), "expected window waits for minimum duration and stable focus");
Check(!settledWindow.Observe(900, 1, 2, 4, 0, 0, 900, 700) && !settledWindow.Observe(1350, 1, 2, 4, 0, 0, 900, 700) && settledWindow.Observe(1400, 1, 2, 4, 0, 0, 900, 700), "new browser focus restarts settle interval");
Check(!settledWindow.Observe(1500, 0, 0, 0, 0, 0, 0, 0) && !settledWindow.Observe(1700, 1, 2, 4, 0, 0, 900, 700), "unverified foreground invalidates accumulated settle time");
Check(settledWindow.Expired(4100) && !settledWindow.Observe(4200, 1, 2, 4, 0, 0, 900, 700), "window settle has nonrenewable four-second deadline");
var assistantDefaults = AssistantOptions.Read(null);
Check(assistantDefaults == new AssistantOptions(), "Assistant defaults inherit separately without changing dictation");
Check(AssistantOptions.Read(assistantDefaults.ToJson()) == assistantDefaults, "Assistant preferences roundtrip");
Check(Invalid(() => AssistantOptions.Read(System.Text.Json.Nodes.JsonNode.Parse("{\"timeoutMs\":180001}"))), "Assistant timeout bounded");
Check(Invalid(() => AssistantOptions.Read(System.Text.Json.Nodes.JsonNode.Parse("{\"model\":[]}"))), "malformed Assistant preference rejected");
var options = new AssistantOptions("provider", "strong-model", "high");
using (var request = System.Text.Json.JsonDocument.Parse(AssistantProtocol.Request("Explain the chart", new("image/png", "AAAA"), options, "Test app", "Test window", [new("user", "Earlier question"), new("assistant", "Earlier answer")])))
{
    Check(request.RootElement.GetProperty("operation").GetString() == "assistant" && request.RootElement.GetProperty("options").GetProperty("model").GetString() == "strong-model", "Assistant request freezes saved picks");
    Check(request.RootElement.GetProperty("images").GetArrayLength() == 1, "one invocation image in request");
    Check(request.RootElement.GetProperty("intent").GetString() == "screen_ask" && !request.RootElement.GetProperty("context").TryGetProperty("apps", out _), "screen question carries no app inventory or action intent");
    Check(request.RootElement.GetProperty("messages").GetArrayLength() == 2 && request.RootElement.GetProperty("messages")[1].GetProperty("content").GetString() == "Earlier answer", "read-only follow-up preserves explicit text conversation");
}
using (var request = System.Text.Json.JsonDocument.Parse(AssistantProtocol.Rewrite("selected", "shorten", options)))
    Check(request.RootElement.GetProperty("profile").GetString() == "assistant" && request.RootElement.GetProperty("selection").GetString() == "selected", "selected rewrite uses separate Assistant profile");
Check(!BridgeProtocol.Dictate("raw", true).Contains("strong-model"), "dictation request never inherits Assistant model");
const string catalog = """
{"version":1,"operation":"catalog","status":"ok","selected":{"provider":"test","model":"test-vision","effort":"high"},"providers":[{"id":"test","label":"Test connection","available":true,"catalogSource":"static-reviewed","models":[{"id":"test-vision","label":"Vision model","vision":true,"efforts":["low","high"],"defaultEffort":"low","operations":["screen_ask","edit_selection"]}]}]}
""";
Check(AssistantProtocol.Catalog(Reply(catalog))?.Providers[0].Models[0].Efforts.SequenceEqual(new[] { "low", "high" }) == true, "generic catalog model and effort parsed");
Check(AssistantProtocol.Catalog(Reply(catalog.Replace("\"version\":1", "\"version\":2"))) == null, "unsupported catalog version rejected");
Check(AssistantProtocol.Catalog(Reply(catalog.Replace("\"test-vision\",\"label\"", "null,\"label\""))) == null, "null catalog model rejected");
Check(AssistantProtocol.Parse(Reply("{\"version\":1,\"operation\":\"assistant\",\"status\":\"ok\",\"kind\":\"answer\",\"text\":\"The answer.\"}")).Text == "The answer.", "complete Assistant answer accepted");
foreach (var unsupported in new[] {
    "{\"version\":1,\"operation\":\"assistant\",\"status\":\"ok\",\"kind\":\"blender\",\"text\":\"Old artifact\",\"artifacts\":{\"blendPath\":\"C:/example/Scene.blend\",\"previewPath\":\"C:/example/Preview.png\"}}",
    "{\"version\":1,\"operation\":\"assistant\",\"status\":\"ok\",\"kind\":\"answer\",\"text\":\"Mixed response\",\"actions\":[]}",
    "{\"version\":1,\"operation\":\"assistant\",\"status\":\"ok\",\"kind\":\"answer\",\"text\":\"Mixed response\",\"artifacts\":{}}",
    "{\"version\":1,\"operation\":\"assistant\",\"status\":\"ok\",\"kind\":\"answer\",\"text\":\"Mixed response\",\"scene\":{}}",
    "{\"version\":1,\"operation\":\"assistant\",\"status\":\"ok\",\"kind\":\"answer\",\"text\":\"Mixed response\",\"command\":\"unexpected\"}",
    "{\"version\":1,\"operation\":\"assistant\",\"status\":\"ok\",\"kind\":\"answer\",\"text\":\"unfinished"
})
{
    var refusedScreenReply = AssistantProtocol.Parse(Reply(unsupported));
    Check(refusedScreenReply.Status == "error" && refusedScreenReply.Kind == null && refusedScreenReply.Text == null, "screen answers reject stale artifacts mixed fields and malformed responses");
}

Check(AssistantProtocol.Parse(Reply("{\"version\":1,\"operation\":\"assistant\",\"status\":\"fallback\",\"text\":\"do not show\"}")).Text == null, "Assistant failure does not expose fallback text");
Check(AssistantProtocol.Parse(new(false, "private request", "timeout")).Text == null, "Assistant timeout cannot become answer");
var assistantTimeout = AssistantProtocol.Parse(Reply("{\"version\":1,\"operation\":\"assistant\",\"status\":\"error\",\"reason\":\"timeout\"}"));
Check(assistantTimeout.Status == "error" && assistantTimeout.FailureCode == "timeout" && assistantTimeout.Text == null && assistantTimeout.FailureMessage == "The selected AI took too long to respond to this step.", "typed Assistant timeout retains a specific safe explanation");
Check(AssistantProtocol.Parse(new(false, "private request", "timeout")).FailureCode == "timeout", "transport timeout retains its fixed Assistant category");
const string privateFailureSentinel = "synthetic-private-reason-never-display";
var originalOut = Console.Out; var originalError = Console.Error;
using var failureLogs = new StringWriter();
AssistantReply privateAssistantFailure;
try
{
    Console.SetOut(failureLogs); Console.SetError(failureLogs);
    privateAssistantFailure = AssistantProtocol.Parse(Reply(System.Text.Json.JsonSerializer.Serialize(new { version = 1, operation = "assistant", status = "error", reason = privateFailureSentinel, text = privateFailureSentinel })));
}
finally { Console.SetOut(originalOut); Console.SetError(originalError); }
Check(privateAssistantFailure.FailureCode == "unavailable" && privateAssistantFailure.Text == null && privateAssistantFailure.FailureMessage == "The AI connection could not finish this step." && !privateAssistantFailure.ToString().Contains(privateFailureSentinel) && !System.Text.Json.JsonSerializer.Serialize(privateAssistantFailure).Contains(privateFailureSentinel) && failureLogs.ToString().Length == 0, "unknown Assistant reason and body are discarded without display or logging");
Check(AssistantProtocol.Parse(new(false, privateFailureSentinel, privateFailureSentinel)).FailureCode == "unavailable" && AssistantProtocol.Parse(new(false, privateFailureSentinel, privateFailureSentinel)).Text == null, "unknown transport failure remains private");
foreach (var failure in new (string Reason, string Code, string Message)[] {
    ("authentication_failed", "authentication_failed", "The AI connection needs you to sign in again through its CLI."),
    ("provider_access_denied", "access_denied", "The AI account does not allow this request. Check access in the selected CLI."),
    ("billing_error", "billing_error", "The AI provider reported a billing problem. Check the account used by its CLI."),
    ("rate_limited", "rate_limited", "The AI provider has reached a usage or rate limit. Try again when access resets."),
    ("provider_request_rejected", "provider_rejected", "The AI provider rejected this request. Try a fresh Option request; if it repeats, check the selected model."),
    ("provider_unavailable", "provider_unavailable", "The AI provider is temporarily unavailable. Try the Option request again shortly."),
    ("cli_launch_failed", "connection_failed", "The AI connection failed while processing this step."),
    ("cli_stdin_failed", "connection_failed", "The AI connection failed while processing this step.")
})
{
    var safeFailure = AssistantProtocol.Parse(Reply(System.Text.Json.JsonSerializer.Serialize(new { version = 1, operation = "assistant", status = "error", reason = failure.Reason, text = privateFailureSentinel, actions = new[] { new { type = "click", x = 0.5, y = 0.5 } } })));
    Check(safeFailure.Status == "error" && safeFailure.FailureCode == failure.Code && safeFailure.FailureMessage == failure.Message && safeFailure.Kind == null && safeFailure.Text == null && !System.Text.Json.JsonSerializer.Serialize(safeFailure).Contains(privateFailureSentinel), "sanitized Assistant failure retains only safe category: " + failure.Reason);
}
Check(AssistantReply.Failed("input_too_large").FailureCode == "request_rejected" && AssistantReply.Failed("input_too_large").FailureMessage == "The screen request could not be sent in its current form." && AssistantReply.Failed("provider_request_rejected").FailureCode == "provider_rejected", "provider rejection remains distinct from local input validation");
var privateDenial = AssistantProtocol.Parse(Reply(System.Text.Json.JsonSerializer.Serialize(new { version = 1, operation = "assistant", status = "error", reason = "provider_access_denied:" + privateFailureSentinel, text = privateFailureSentinel, actions = new[] { new { type = "click", x = 0.5, y = 0.5 } } })));
Check(privateDenial.FailureCode == "unavailable" && privateDenial.FailureMessage == "The AI connection could not finish this step." && privateDenial.Text == null && !privateDenial.ToString().Contains(privateFailureSentinel), "unknown private denial text cannot masquerade as an allowlisted category");
Check(AssistantProtocol.Parse(Reply("{\"version\":1,\"operation\":\"assistant\",\"status\":\"ok\",\"kind\":\"shell\",\"text\":\"bad\"}")).Text == null, "arbitrary action kind rejected");
bool Capture(long currentWindow = 1, uint currentProcess = 2, uint ownProcess = 9, bool minimized = false, bool cloaked = false, bool affinityKnown = true, uint affinity = 0, int width = 1920, int height = 1080)
    => WindowCapturePolicy.Allowed(1, 2, currentWindow, currentProcess, ownProcess, true, minimized, cloaked, affinityKnown, affinity, width, height);
Check(Capture(), "owned invocation HWND policy allows supported capture");
Check(!Capture(currentWindow: 3) && !Capture(currentProcess: 4), "changed foreground identity blocks capture");
Check(!Capture(ownProcess: 2), "Sona own windows excluded from capture");
Check(!Capture(affinity: 1) && !Capture(affinity: 0x11) && !Capture(affinityKnown: false), "protected or unknown capture affinity blocks pixels");
Check(!Capture(minimized: true) && !Capture(cloaked: true), "invisible window capture refused");
Check(!Capture(width: 8193) && !Capture(width: 8192, height: 8192) && !Capture(width: 0), "capture allocation hard bounds");
Check(AssistantProtocol.Catalog(Reply(catalog.Replace("[\"low\",\"high\"]", "[]").Replace("\"defaultEffort\":\"low\"", "\"defaultEffort\":\"default\"")))?.Providers[0].Models[0].Efforts.Length == 0, "model without effort setting remains valid catalog entry");
var chat = new TemporaryChat();
for (int i = 0; i < 20; i++) chat.Add(i % 2 == 0 ? "user" : "assistant", "Message " + i);
Check(chat.Messages.Length == 16 && chat.Messages[0].Content == "Message 4", "temporary chat drops oldest messages at count bound");
chat.Clear(); chat.Add("user", new string('x', 16000)); chat.Add("assistant", new string('x', 16000)); chat.Add("user", new string('x', 16000));
Check(chat.Messages.Length == 2, "temporary history byte bound");
chat.Clear(); Check(chat.Messages.Length == 0, "Close can erase temporary history");
Check(Invalid(() => chat.Add("system", "untrusted")), "temporary chat rejects injected system role");
Check(Invalid(() => chat.Add("user", new string('x', 16385))), "single temporary message byte bound");
long actionNow = 0; var actionBudget = new ActionBudget(() => actionNow);
Check(Enumerable.Range(0, 12).All(_ => actionBudget.TryDispatch()) && !actionBudget.TryDispatch(), "maximum twelve actions per spoken request");
var deadlineBudget = new ActionBudget(() => actionNow); actionNow = 180000; Check(!deadlineBudget.Active && !deadlineBudget.TryDispatch(), "action chain has nonrenewable three-minute deadline");
AssistantAction ParseAction(string text) { using var doc = System.Text.Json.JsonDocument.Parse(text); return AssistantActionPolicy.Parse(doc.RootElement); }
Check(ParseAction("{\"type\":\"click\",\"x\":0.25,\"y\":1}").X == .25, "normalized click parser");
Check(Invalid(() => ParseAction("{\"type\":\"click\",\"x\":-1,\"y\":0}")), "off-window click rejected");
Check(Invalid(() => ParseAction("{\"type\":\"key\",\"key\":\"cmd+v\"}")), "unapproved clipboard shortcut rejected");
Check(Invalid(() => ParseAction("{\"type\":\"shell\",\"text\":\"run\"}")), "arbitrary shell action rejected");
Check(Invalid(() => ParseAction("{\"type\":\"open_url\",\"url\":\"file:///C:/Windows/system32/cmd.exe\"}")), "non-HTTP action URL rejected");
Check(Invalid(() => ParseAction("{\"type\":\"scroll\",\"direction\":\"down\",\"amount\":6}")), "scroll action bounded");
Check(ParseAction("{\"type\":\"wait\",\"milliseconds\":250}").Milliseconds == 250 && ParseAction("{\"type\":\"wait\",\"milliseconds\":1500,\"requiresConfirmation\":true}").RequiresConfirmation, "wait duration boundaries and optional confirmation preserved");
Check(new[] { "{\"type\":\"wait\"}", "{\"type\":\"wait\",\"milliseconds\":249}", "{\"type\":\"wait\",\"milliseconds\":1501}", "{\"type\":\"wait\",\"milliseconds\":250.5}", "{\"type\":\"wait\",\"milliseconds\":\"750\"}", "{\"type\":\"wait\",\"milliseconds\":750,\"text\":\"unexpected\"}" }.All(json => Invalid(() => ParseAction(json))), "wait rejects missing fractional out-of-range or extra fields");
Check(!AssistantActionPolicy.Confirm(ParseAction("{\"type\":\"wait\",\"milliseconds\":750}")), "bounded wait needs no automatic confirmation");
int waitGuards = 0;
Check(await AssistantWait.RunAsync(250, () => { waitGuards++; return true; }, CancellationToken.None) && waitGuards == 2, "wait verifies the same target before and after its delay");
waitGuards = 0;
Check(!await AssistantWait.RunAsync(250, () => ++waitGuards == 1, CancellationToken.None), "target change during wait prevents continuation");
waitGuards = 0;
Check(!await AssistantWait.RunAsync(250, () => { waitGuards++; return false; }, CancellationToken.None) && waitGuards == 1, "wait refuses an already invalid target");
using (var cancelWait = new CancellationTokenSource())
{
    waitGuards = 0; bool cancelledWait = false;
    var pendingWait = AssistantWait.RunAsync(1500, () => { waitGuards++; return true; }, cancelWait.Token);
    cancelWait.Cancel();
    try { await pendingWait; } catch (OperationCanceledException) { cancelledWait = true; }
    Check(cancelledWait && waitGuards == 1, "cancelled wait cannot claim completion or recheck the target");
}
bool invalidNativeWait = false;
try { await AssistantWait.RunAsync(1501, () => true, CancellationToken.None); } catch (InvalidDataException) { invalidNativeWait = true; }
Check(invalidNativeWait, "native wait also refuses an unvalidated duration");
Check(AssistantActionPolicy.Confirm(new("key", Key: "enter")) && AssistantActionPolicy.Confirm(new("key", Key: "shift+enter")), "both Enter variants always require native approval");
Check(AssistantActionPolicy.Confirm(new("click"), "Delete draft") && AssistantActionPolicy.Confirm(new("click"), "Send now") && !AssistantActionPolicy.Confirm(new("click"), "Preview"), "native consequential control labels require approval");
Check(AssistantActionPolicy.Terminal("pwsh", "Editor") && AssistantActionPolicy.Terminal("Code", "Integrated Terminal") && !AssistantActionPolicy.Terminal("Code", "Program.cs editor"), "terminal injection denied while code editor remains supported");
Check(AssistantProtocol.Parse(Reply("{\"version\":1,\"operation\":\"assistant\",\"status\":\"ok\",\"kind\":\"actions\",\"text\":\"Click preview.\",\"actions\":[{\"type\":\"click\",\"x\":0.4,\"y\":0.5}]}")).Status == "error", "stale typed action response rejected");
Check(AssistantProtocol.Parse(Reply("{\"version\":1,\"operation\":\"assistant\",\"status\":\"ok\",\"kind\":\"actions\",\"text\":\"Many\",\"actions\":[]}")).Status == "error", "stale action response without actions rejected");
string temp = Path.Combine(Path.GetTempPath(), "Sona-core-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(temp);
try
{
    string config = Path.Combine(temp, "settings.json");
    Check(!SettingsStore.Load(config).SetupComplete, "blank machine requires setup");
    Check(SettingsStore.Load(config).CleanupEnabled, "new setup enables selected AI cleanup");
    SettingsStore.Save(config, new AppSettings { CleanupEnabled = false });
    Check(!SettingsStore.Load(config).CleanupEnabled, "explicit cleanup opt-out persists");
    await File.WriteAllTextAsync(config, "{\"version\":1,\"setupComplete\":true,\"cleanupEnabled\":false,\"shortcut\":{\"virtualKey\":163,\"modifiers\":0}}");
    var migrated = SettingsStore.Load(config);
    Check(migrated.SetupComplete && !migrated.CleanupEnabled && !migrated.AutoAddToDictionary && migrated.Shortcut.VirtualKey == 163, "old configuration preserves choices with observer off");
    foreach (string retired in new[] { "null", "true", "[]", "\"invalid\"", "{\"virtualKey\":165,\"modifiers\":0}", "{\"virtualKey\":163,\"modifiers\":0}" })
    {
        await File.WriteAllTextAsync(config, "{\"setupComplete\":true,\"cleanupEnabled\":false,\"shortcut\":{\"virtualKey\":163,\"modifiers\":0},\"commandShortcut\":" + retired + ",\"assistant\":{\"model\":[]}}");
        var legacy = SettingsStore.Load(config);
        Check(legacy.SetupComplete && !legacy.CleanupEnabled && legacy.Shortcut == new Shortcut(0xA3, 0), "retired shortcut shape cannot block or change dictation: " + retired);
        Check(!System.Text.Json.JsonSerializer.Serialize(legacy, SettingsStore.JsonOptions).Contains("commandShortcut"), "loaded legacy settings have no second shortcut: " + retired);
        SettingsStore.Save(config, legacy);
        Check(SettingsStore.Load(config).Shortcut == new Shortcut(0xA3, 0), "saving legacy settings retains primary dictation: " + retired);
    }
    SettingsStore.Save(config, new AppSettings { SetupComplete = true, Shortcut = new Shortcut(0xA3, 0) });
    Check(SettingsStore.Load(config).Shortcut.VirtualKey == 0xA3, "chosen shortcut persists");
    await File.WriteAllTextAsync(config, "{\"futureFeature\":{\"keep\":true},\"shortcut\":{\"virtualKey\":163,\"modifiers\":0},\"autoAddToDictionary\":\"invalid\"}");
    Check(SettingsStore.Load(config).Shortcut.VirtualKey == 163 && !SettingsStore.Load(config).AutoAddToDictionary, "malformed new field does not erase valid old choice");
    SettingsStore.Save(config, SettingsStore.Load(config));
    Check((await File.ReadAllTextAsync(config)).Contains("futureFeature"), "unknown top-level settings preserved");
    await File.WriteAllTextAsync(config, "{bad");
    Check(Invalid(() => SettingsStore.Save(config, new())), "malformed existing settings cannot be overwritten");
    Check(await File.ReadAllTextAsync(config) == "{bad", "malformed settings bytes retained");
    Check(!SettingsStore.Load(config).SetupComplete, "corrupt config returns to setup");
    string transactional = Path.Combine(temp, "transaction.json");
    await File.WriteAllTextAsync(transactional, "{\"keep\":true}");
    Check(Invalid(() => FeatureConfig.CommitDocuments((transactional, new System.Text.Json.Nodes.JsonObject { ["changed"] = true }), (config, new System.Text.Json.Nodes.JsonObject()))), "two-file staging fails before replacing valid first file");
    Check(await File.ReadAllTextAsync(transactional) == "{\"keep\":true}", "transaction failure retains previous file");
    byte[] payload = Encoding.UTF8.GetBytes("verified test model");
    var spec = new DownloadSpec(new Uri("https://example.invalid/test"), payload.Length, Convert.ToHexString(SHA256.HashData(payload)));
    string model = Path.Combine(temp, "model.bin");
    using var http = new HttpClient(new BytesHandler(payload));
    await new VerifiedDownloader(http).DownloadAsync(model, spec, null, CancellationToken.None);
    Check(await VerifiedDownloader.IsValidAsync(model, spec), "download size and SHA256 validated");
    await File.WriteAllTextAsync(model, "damaged");
    using var badHttp = new HttpClient(new BytesHandler(Encoding.UTF8.GetBytes("bad payload")));
    bool failed = false;
    try { await new VerifiedDownloader(badHttp).DownloadAsync(model, spec, null, CancellationToken.None); } catch (InvalidDataException) { failed = true; }
    Check(failed && await File.ReadAllTextAsync(model) == "damaged", "bad download does not replace prior file");
    using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
    bool cancelled = false;
    try { await new VerifiedDownloader(http).DownloadAsync(model, spec, null, cancellation.Token); } catch (OperationCanceledException) { cancelled = true; }
    Check(cancelled && !Directory.EnumerateFiles(temp, "*.partial").Any(), "cancel removes only partial download");
    byte[] large = new byte[200000]; Random.Shared.NextBytes(large);
    using var largeHttp = new HttpClient(new BytesHandler(large));
    using var midCancel = new CancellationTokenSource();
    var largeSpec = new DownloadSpec(spec.Url, large.Length, Convert.ToHexString(SHA256.HashData(large)));
    bool midCancelled = false;
    try { await new VerifiedDownloader(largeHttp).DownloadAsync(model, largeSpec, new InlineProgress(_ => midCancel.Cancel()), midCancel.Token); }
    catch (OperationCanceledException) { midCancelled = true; }
    Check(midCancelled && !Directory.EnumerateFiles(temp, "*.partial").Any() && await File.ReadAllTextAsync(model) == "damaged", "mid-download cancellation preserves prior model and removes partial");
    string executable = Environment.ProcessPath!;
    var prefix = Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)
        ? new[] { typeof(BytesHandler).Assembly.Location } : Array.Empty<string>();
    const string raw = "Exact transcript.\nUnicode ✓ and $ literal.";
    foreach (var mode in new[] { "echo", "empty", "fail", "hang", "flood" })
    {
        var watch = Stopwatch.StartNew();
        var result = await BoundedProcess.RunAsync(executable, prefix.Concat(new[] { "--child", mode }), raw, TimeSpan.FromMilliseconds(700));
        Check(result.Output == raw && result.Success == (mode == "echo"), "process " + mode + " preserves original");
        Check(watch.Elapsed < TimeSpan.FromSeconds(5), "process " + mode + " is bounded");
    }
}
finally { Directory.Delete(temp, recursive: true); }
// Recording panel parity with the Mac (vectors computed with the verbatim AudioCapture.updateSpectrum math).
float[] Bands(float[] samples, float rate) { var bands = new float[PanelSpectrum.BandCount]; PanelSpectrum.Analyze(samples, rate, bands); return bands; }
bool Near(float[] actual, float[] expected) => actual.Length == expected.Length && actual.Zip(expected).All(p => Math.Abs(p.First - p.Second) <= 0.002f);
Check(Math.Abs(PanelSpectrum.Frequency(0) - 80) < 0.01 && Math.Abs(PanelSpectrum.Frequency(27) - 955.55) < 0.05 && Math.Abs(PanelSpectrum.Frequency(47) - 6000) < 0.5, "panel spectrum band centers match the Mac");
var vectorA = Enumerable.Range(0, 4410).Select(i => (float)(0.1 * Math.Sin(2 * Math.PI * 1000 * i / 44100.0))).ToArray();
var expectedA = new float[48]; expectedA[27] = 1; expectedA[28] = 1; expectedA[29] = 0.2629f;
Check(Near(Bands(vectorA, 44100), expectedA), "panel spectrum vector A (1 kHz sine)");
var vectorB = Enumerable.Range(0, 4800).Select(i => { double t = i / 48000.0; return (float)(0.3 * Math.Sin(2 * Math.PI * 300 * t) + 0.05 * Math.Sin(2 * Math.PI * 2500 * t)); }).ToArray();
var expectedB = new float[48];
new float[] { 0.0000f, 0.0182f, 0.0374f, 0.0000f, 0.0000f, 0.1456f, 0.2565f, 0.1632f, 0.2476f, 0.5280f, 0.4470f, 0.8095f, 1.0000f, 1.0000f, 1.0000f, 1.0000f, 1.0000f, 0.8519f, 0.6234f, 0.3978f, 0.2096f, 0.0817f, 0.0000f }.CopyTo(expectedB, 0);
expectedB[37] = 0.4438f; expectedB[38] = 0.3719f;
Check(Near(Bands(vectorB, 48000), expectedB), "panel spectrum vector B (300 Hz and 2.5 kHz)");
Check(Bands(new float[1024], 48000).All(v => v == 0), "panel spectrum vector C (silence)");
uint lcg = 12345;
var vectorD = Enumerable.Range(0, 1024).Select(_ => { lcg = unchecked(lcg * 1664525 + 1013904223); return ((lcg >> 8) / (float)(1 << 24) * 2 - 1) * 0.05f; }).ToArray();
Check(Near(Bands(vectorD, 48000), new[] { 0.2080f, 0.2017f, 0.1901f, 0.1733f, 0.1534f, 0.1380f, 0.1408f, 0.1722f, 0.2195f, 0.2589f, 0.2717f, 0.2457f, 0.1825f, 0.1287f, 0.0915f, 0.1568f, 0.1763f, 0.3079f, 0.5203f, 0.3901f, 0.3777f, 0.2606f, 0.3889f, 0.2987f, 0.4729f, 0.3679f, 0.0885f, 0.3387f, 0.3120f, 0.3758f, 0.4705f, 0.1962f, 0.3277f, 0.3615f, 0.1409f, 0.5269f, 0.3009f, 0.4609f, 0.5556f, 0.4218f, 0.7325f, 0.5955f, 0.0000f, 0.5687f, 0.8198f, 0.2948f, 0.3085f, 0.6877f }), "panel spectrum vector D (noise)");
var synthetic = new float[48]; PanelSpectrum.Synthetic(0.1, synthetic);
Check(synthetic.All(v => v >= 0.05f && v <= 1f) && Math.Abs(synthetic[0] - (float)(0.45 + 0.3 * Math.Sin(0.26) + 0.2 * Math.Sin(0.61))) < 1e-6, "panel preview synthetic voice matches the Mac formula");
var bars = new BarMotion();
bars.StartRecording();
Check(bars.Height(0) == 2 && Math.Abs(bars.Alpha(0) - 0.55) < 1e-12, "silent bars are 2 DIP dots at alpha 0.55");
var loud = Enumerable.Repeat(1f, 48).ToArray(); bars.SetSpectrum(loud);
bars.Advance(1 / 60.0);
Check(Math.Abs(bars.Level(0) - 0.45) < 1e-9 && Math.Abs(bars.Level(BarMotion.BarCount - 1) - (0.45 + 0.15 * (47 % 3) / 2.0)) < 1e-9, "bars rise at the Mac per-band rates");
for (int i = 0; i < 600; i++) bars.Advance(1 / 60.0);
Check(Math.Abs(bars.Height(10) - (2 + 56 * (0.9 + 0.1 * (Math.Sin(bars.Phase + 7) * 0.5 + 0.5)))) < 1e-6 && Math.Abs(bars.Alpha(10) - 1) < 1e-9, "full bands reach the shimmering 58 DIP top at alpha 1");
var stepped = new BarMotion(); stepped.StartRecording(); stepped.SetSpectrum(loud); stepped.Advance(1 / 30.0);
var twice = new BarMotion(); twice.StartRecording(); twice.SetSpectrum(loud); twice.Advance(1 / 60.0); twice.Advance(1 / 60.0);
Check(Math.Abs(stepped.Level(30) - twice.Level(30)) < 1e-9, "bar easing is frame-rate independent");
bars.StartProcessing(); bars.SetSpectrum(new float[48]);
for (int i = 0; i < 300; i++) bars.Advance(1 / 60.0);
Check(Enumerable.Range(0, BarMotion.BarCount).All(i => bars.Level(i) > 0.09 && bars.Level(i) < 0.63), "processing wave stays between 0.10 and 0.62");
bars.Stop();
Check(bars.Mode == BarMode.Idle && bars.Level(40) == 0 && bars.Height(40) == 2, "stopping returns the bars to zero");
var script = LightScript.Generate(new Random(5));
var rest = script.At(0);
Check(rest.One == 0 && rest.Two == 0 && rest.Tail == 1, "lights start merged at rest with the tail lit");
Check(script.Total > 82 && script.Total < 95, "light script lasts about 90 seconds");
var end = script.At(script.Total - 1e-9);
Check(Math.Abs(Math.IEEERemainder(end.One, 2 * Math.PI)) < 1e-6 && Math.Abs(Math.IEEERemainder(end.Two, 2 * Math.PI)) < 1e-6, "light script homes to rest so it repeats seamlessly");
var split = script.At(0.6);
Check(Math.Sign(split.One) != Math.Sign(split.Two) && split.Tail < 1, "lights leave in opposite directions and the tail fades");
Check(LightScript.EaseInOut(0.5) is > 0.4999 and < 0.5001 && LightScript.EaseInOut(0.25) is > 0.12 and < 0.13, "ease in and out matches cubic-bezier(0.42, 0, 0.58, 1)");
Check(PanelTiming.Smoothstep(0.5) == 0.5 && PanelTiming.Smoothstep(1) == 1, "dismissal smoothstep");
// W1: English is the default for new installs; a saved choice, including "auto", is kept.
Check(new AppSettings().Language == "en" && AppSettings.DefaultLanguage == "en", "new installs default to English");
Check(new AppSettings { Language = "auto" }.Validate().Language == "auto", "auto stays selectable");
Check(new AppSettings { Language = "  " }.Validate().Language == "en" && new AppSettings { Language = " de " }.Validate().Language == "de", "blank language falls back to English and a choice is trimmed");
string languageTemp = Path.Combine(Path.GetTempPath(), "Sona-language-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(languageTemp);
try
{
    string languageConfig = Path.Combine(languageTemp, "settings.json");
    Check(SettingsStore.Load(languageConfig).Language == "en", "blank machine starts in English");
    await File.WriteAllTextAsync(languageConfig, "{\"setupComplete\":true,\"language\":\"auto\"}");
    Check(SettingsStore.Load(languageConfig).Language == "auto", "an existing explicit auto choice is kept");
    SettingsStore.Save(languageConfig, SettingsStore.Load(languageConfig));
    Check(SettingsStore.Load(languageConfig).Language == "auto", "saving keeps an explicit auto choice");
    await File.WriteAllTextAsync(languageConfig, "{\"setupComplete\":true,\"language\":\"fr\"}");
    Check(SettingsStore.Load(languageConfig).Language == "fr", "an existing explicit language is kept");
    await File.WriteAllTextAsync(languageConfig, "{\"setupComplete\":true}");
    Check(SettingsStore.Load(languageConfig).Language == "en", "settings with no language use the English default");
    await File.WriteAllTextAsync(languageConfig, "{\"setupComplete\":true,\"language\":7}");
    Check(SettingsStore.Load(languageConfig).Language == "en", "a malformed language uses the English default");
}
finally { Directory.Delete(languageTemp, recursive: true); }
// W2: English gets the English-only base.en model; auto and other languages keep multilingual base.
Check(SpeechModels.For("en") == SpeechModels.English && SpeechModels.For(" EN ") == SpeechModels.English && SpeechModels.For(new AppSettings().Language) == SpeechModels.English, "English selects base.en");
Check(SpeechModels.For("auto") == SpeechModels.Multilingual && SpeechModels.For("fr") == SpeechModels.Multilingual && SpeechModels.For(null) == SpeechModels.Multilingual, "auto and other languages keep multilingual base");
Check(SpeechModels.English.FileName == "ggml-base.en.bin" && SpeechModels.English.EnglishOnly && SpeechModels.English.Download.Size == 147964211
    && SpeechModels.English.Download.Sha256 == "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002", "base.en pinned to its official LFS size and SHA-256");
Check(SpeechModels.Multilingual.FileName == "ggml-base.bin" && !SpeechModels.Multilingual.EnglishOnly && SpeechModels.Multilingual.Download == VerifiedDownloader.BaseModel
    && VerifiedDownloader.BaseModel.Sha256 == "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe", "multilingual base pin unchanged");
Check(new[] { SpeechModels.English, SpeechModels.Multilingual }.All(m => m.Download.Url.Scheme == "https" && m.Download.Url.Host == "huggingface.co"
    && m.Download.Url.AbsolutePath == "/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/" + m.FileName), "both models download from the same pinned whisper.cpp revision");
Check(SpeechModels.WhisperLanguage(SpeechModels.English, "en") == "en" && SpeechModels.WhisperLanguage(SpeechModels.English, "EN") == "en"
    && SpeechModels.WhisperLanguage(SpeechModels.Multilingual, "auto") == "auto" && SpeechModels.WhisperLanguage(SpeechModels.Multilingual, "fr") == "fr", "English-only model always hears en");
// Phase B: English runs on Parakeet once verified; Whisper is the backup and the engine for auto and other languages.
Check(SpeechEngines.Preferred("en") == SpeechEngine.Parakeet && SpeechEngines.Preferred(" EN ") == SpeechEngine.Parakeet
    && SpeechEngines.Preferred(new AppSettings().Language) == SpeechEngine.Parakeet, "English prefers Parakeet");
Check(SpeechEngines.Preferred("auto") == SpeechEngine.Whisper && SpeechEngines.Preferred("fr") == SpeechEngine.Whisper
    && SpeechEngines.Preferred("de") == SpeechEngine.Whisper && SpeechEngines.Preferred(null) == SpeechEngine.Whisper && SpeechEngines.Preferred("") == SpeechEngine.Whisper, "auto and other languages stay on Whisper");
Check(SpeechEngines.ForDictation("en", parakeetVerified: false) == SpeechEngine.Whisper && SpeechEngines.ForDictation("en", parakeetVerified: true) == SpeechEngine.Parakeet,
    "English dictates on Whisper until Parakeet is verified, then switches");
Check(SpeechEngines.ForDictation("auto", true) == SpeechEngine.Whisper && SpeechEngines.ForDictation("ja", true) == SpeechEngine.Whisper, "a verified Parakeet never takes auto or other languages");
Check(SpeechModels.For("en") == SpeechModels.English, "English keeps base.en as its Whisper backup");
Check(SpeechEngines.FallBackToWhisper(new InvalidDataException(), cancelled: false) && SpeechEngines.FallBackToWhisper(new DllNotFoundException(), false)
    && SpeechEngines.FallBackToWhisper(new SEHException(), false), "a Parakeet load or decode failure runs that dictation on Whisper");
Check(!SpeechEngines.FallBackToWhisper(new OperationCanceledException(), false) && !SpeechEngines.FallBackToWhisper(new TaskCanceledException(), false)
    && !SpeechEngines.FallBackToWhisper(new InvalidDataException(), cancelled: true), "a cancelled dictation is not retried on Whisper");
Check(new[] { SpeechEngines.ParakeetLoadFailed, SpeechEngines.ParakeetDecodeFailed, SpeechEngines.ParakeetDownloadFailed }.All(code => System.Text.RegularExpressions.Regex.IsMatch(code, "^[a-z_]+$")),
    "Parakeet failures log fixed codes");
var health = new ParakeetHealth();
Check(health.ShouldTry("A") && health.ShouldTry("B"), "Parakeet is tried until it fails");
health.LoadFailed("A");
Check(!health.ShouldTry("A") && !health.ShouldTry("a") && health.ShouldTry("B"), "a folder that failed to load is not retried this session; others still are");
for (int i = 1; i < ParakeetHealth.MaximumDecodeFailures; i++) health.DecodeFailed("B");
Check(health.ShouldTry("B"), "a failed decode retries a fresh load next time");
health.Succeeded("B"); for (int i = 1; i < ParakeetHealth.MaximumDecodeFailures; i++) health.DecodeFailed("B");
Check(health.ShouldTry("B"), "a success resets the decode failure count");
health.DecodeFailed("B");
Check(!health.ShouldTry("B"), $"{ParakeetHealth.MaximumDecodeFailures} decode failures in a row leave the folder to Whisper");
// The pinned Parakeet bundle: four plain files from one Hugging Face commit, with LFS sizes and SHA-256.
var parakeet = SpeechModels.Parakeet;
Check(parakeet.Files.Select(f => f.Name).SequenceEqual(new[] { "encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt" }), "Parakeet bundle has its four files");
Check(parakeet.Files.All(f => Path.GetFileName(f.Name) == f.Name && f.Download.Url.Scheme == "https" && f.Download.Url.Host == "huggingface.co"
    && f.Download.Url.AbsolutePath == "/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/resolve/1ab9323565ddb038682214b292f588070a538ce2/" + f.Name
    && f.Download.Sha256.Length == 64 && f.Download.Size > 0), "Parakeet files download from one pinned commit");
Check(parakeet.Files[0].Download is { Size: 652184296, Sha256: "a32b12d17bbbc309d0686fbbcc2987b5e9b8333a7da83fa6b089f0a2acd651ab" }
    && parakeet.Files[1].Download is { Size: 7257753, Sha256: "b6bb64963457237b900e496ee9994b59294526439fbcc1fecf705b31a15c6b4e" }
    && parakeet.Files[2].Download is { Size: 1739080, Sha256: "7946164367946e7f9f29a122407c3252b680dbae9a51343eb2488d057c3c43d2" }
    && parakeet.Files[3].Download is { Size: 9384, Sha256: "ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d" }
    && parakeet.TotalSize == 661190513, "Parakeet sizes and SHA-256 match the pinned LFS metadata");
string bundleTemp = Path.Combine(Path.GetTempPath(), "sona-bundle-" + Guid.NewGuid().ToString("N"));
try
{
    byte[] one = Encoding.UTF8.GetBytes("first model file"), two = new byte[150000], three = Encoding.UTF8.GetBytes("tokens 0\n");
    new Random(7).NextBytes(two);
    DownloadSpec Spec(string name, byte[] bytes) => new(new Uri("https://example.invalid/bundle/" + name), bytes.Length, Convert.ToHexString(SHA256.HashData(bytes)));
    var bundle = new ModelBundle("test-bundle", [new("a.onnx", Spec("a.onnx", one)), new("b.onnx", Spec("b.onnx", two)), new("tokens.txt", Spec("tokens.txt", three))]);
    var served = new Dictionary<string, byte[]> { ["/bundle/a.onnx"] = one, ["/bundle/b.onnx"] = two, ["/bundle/tokens.txt"] = three };
    var handler = new RoutesHandler(served);
    using var bundleHttp = new HttpClient(handler);
    string folder = Path.Combine(bundleTemp, bundle.FolderName);
    Check(!await VerifiedDownloader.IsValidAsync(folder, bundle), "a missing bundle is not valid");
    var reports = new List<double>();
    await new VerifiedDownloader(bundleHttp).DownloadAsync(folder, bundle, new InlineProgress(reports.Add), CancellationToken.None);
    Check(await VerifiedDownloader.IsValidAsync(folder, bundle) && handler.Requests == 3, "good bundle downloads every file and verifies");
    Check(reports.Count > 0 && reports.Zip(reports.Skip(1)).All(pair => pair.Second >= pair.First) && reports[^1] == 1 && reports.All(r => r >= 0 && r <= 1), "bundle progress rises to 1 across files");
    Check(!Directory.EnumerateFiles(folder).Any(f => f.EndsWith(".partial", StringComparison.Ordinal)), "no temporary files remain after a good bundle");
    File.Delete(Path.Combine(folder, "b.onnx"));
    Check(!await VerifiedDownloader.IsValidAsync(folder, bundle), "a bundle with a missing file is not valid");
    await new VerifiedDownloader(bundleHttp).DownloadAsync(folder, bundle, null, CancellationToken.None);
    Check(await VerifiedDownloader.IsValidAsync(folder, bundle) && handler.Requests == 4, "a missing file is fetched alone; verified files are kept");
    // A run killed by shutdown or a hard exit leaves "name.guid.partial" behind; the next run clears them.
    string orphanA = Path.Combine(folder, "a.onnx." + Guid.NewGuid().ToString("N") + ".partial");
    string orphanB = Path.Combine(folder, "b.onnx." + Guid.NewGuid().ToString("N") + ".partial");
    string unrelated = Path.Combine(folder, "notes.txt.partial");
    foreach (var orphan in new[] { orphanA, orphanB, unrelated }) await File.WriteAllBytesAsync(orphan, new byte[4096]);
    File.Delete(Path.Combine(folder, "a.onnx"));
    await new VerifiedDownloader(bundleHttp).DownloadAsync(folder, bundle, null, CancellationToken.None);
    Check(!File.Exists(orphanA) && !File.Exists(orphanB) && File.Exists(unrelated) && await VerifiedDownloader.IsValidAsync(folder, bundle) && handler.Requests == 5,
        "leftover partials of the bundle's files are deleted on the next run; other files are kept");
    File.Delete(unrelated);
    await File.WriteAllBytesAsync(orphanB, new byte[16]);
    await new VerifiedDownloader(bundleHttp).DownloadAsync(folder, bundle, null, CancellationToken.None);
    Check(!File.Exists(orphanB) && handler.Requests == 5, "leftover partials are cleared even when every file already verifies");
    await File.WriteAllBytesAsync(Path.Combine(folder, "tokens.txt"), Encoding.UTF8.GetBytes("tokens 1\n"));
    Check(!await VerifiedDownloader.IsValidAsync(folder, bundle), "a file with the right size and the wrong hash on disk is not valid");
    await File.WriteAllBytesAsync(Path.Combine(folder, "tokens.txt"), Encoding.UTF8.GetBytes("tokens 0\n extra"));
    Check(!await VerifiedDownloader.IsValidAsync(folder, bundle), "a file with the wrong size on disk is not valid");
    string fresh = Path.Combine(bundleTemp, "wrong-size");
    served["/bundle/b.onnx"] = two.Take(two.Length - 1).ToArray();
    bool wrongSize = false;
    try { await new VerifiedDownloader(bundleHttp).DownloadAsync(fresh, bundle, null, CancellationToken.None); } catch (InvalidDataException) { wrongSize = true; }
    Check(wrongSize && !File.Exists(Path.Combine(fresh, "b.onnx")) && !await VerifiedDownloader.IsValidAsync(fresh, bundle)
        && !Directory.EnumerateFiles(fresh).Any(f => f.EndsWith(".partial", StringComparison.Ordinal)), "a short download is refused, never moved into place, and leaves no temp file");
    served["/bundle/b.onnx"] = two.Concat(new byte[] { 1 }).ToArray();
    bool tooLong = false;
    try { await new VerifiedDownloader(bundleHttp).DownloadAsync(fresh, bundle, null, CancellationToken.None); } catch (InvalidDataException) { tooLong = true; }
    Check(tooLong && !File.Exists(Path.Combine(fresh, "b.onnx")), "an oversized download is refused");
    var tampered = (byte[])two.Clone(); tampered[100] ^= 0xFF; served["/bundle/b.onnx"] = tampered;
    bool wrongHash = false;
    try { await new VerifiedDownloader(bundleHttp).DownloadAsync(fresh, bundle, null, CancellationToken.None); } catch (InvalidDataException) { wrongHash = true; }
    Check(wrongHash && !File.Exists(Path.Combine(fresh, "b.onnx")) && !await VerifiedDownloader.IsValidAsync(fresh, bundle)
        && !Directory.EnumerateFiles(fresh).Any(f => f.EndsWith(".partial", StringComparison.Ordinal)), "a same-size download with the wrong hash is refused and never moved into place");
    served.Remove("/bundle/tokens.txt"); served["/bundle/b.onnx"] = two;
    bool missingRemote = false;
    try { await new VerifiedDownloader(bundleHttp).DownloadAsync(fresh, bundle, null, CancellationToken.None); } catch (HttpRequestException) { missingRemote = true; }
    Check(missingRemote && !await VerifiedDownloader.IsValidAsync(fresh, bundle) && !File.Exists(Path.Combine(fresh, "tokens.txt")), "a file missing on the server leaves the bundle invalid");
    var unsafeBundle = new ModelBundle("bad", [new("../escape.onnx", Spec("x", one))]);
    bool refusedName = false;
    try { await new VerifiedDownloader(bundleHttp).DownloadAsync(Path.Combine(bundleTemp, "bad"), unsafeBundle, null, CancellationToken.None); } catch (InvalidDataException) { refusedName = true; }
    Check(refusedName && !File.Exists(Path.Combine(bundleTemp, "escape.onnx")), "bundle file names cannot leave the model folder");
}
finally { if (Directory.Exists(bundleTemp)) Directory.Delete(bundleTemp, recursive: true); }
// W3: per-window silence check on synthetic audio. Seeded, so every run is identical.
var noiseRandom = new Random(20261104);
double Gaussian() => Math.Sqrt(-2 * Math.Log(1 - noiseRandom.NextDouble())) * Math.Cos(2 * Math.PI * noiseRandom.NextDouble());
float[] Scale(double[] x, double dbfs) { double rms = Math.Sqrt(x.Average(v => v * v)); double gain = Math.Pow(10, dbfs / 20) / Math.Max(rms, 1e-12); return x.Select(v => (float)(v * gain)).ToArray(); }
float[] WhiteNoise(int n, double dbfs) => Scale(Enumerable.Range(0, n).Select(_ => Gaussian()).ToArray(), dbfs);
float[] PinkNoise(int n, double dbfs)
{
    // Paul Kellet's economy pink filter: room and fan noise falls with frequency.
    double b0 = 0, b1 = 0, b2 = 0; var x = new double[n];
    for (int i = 0; i < n; i++) { double w = Gaussian(); b0 = 0.99765 * b0 + w * 0.0990460; b1 = 0.96300 * b1 + w * 0.2965164; b2 = 0.57000 * b2 + w * 1.0526913; x[i] = b0 + b1 + b2 + w * 0.1848; }
    return Scale(x, dbfs);
}
float[] Mix(float[] a, float[] b) => a.Select((v, i) => v + (i < b.Length ? b[i] : 0)).ToArray();
double Rms(float[] x) => Math.Sqrt(x.Average(v => (double)v * v));
// Speech-like audio: voiced syllables (120 Hz with formant-weighted harmonics) of 150 to 250 ms, gaps of 60 to 140 ms.
float[] Syllables(int rate, double seconds, double activeDbfs, double leadSeconds = 0.3)
{
    var x = new double[(int)(rate * seconds)]; int at = (int)(rate * leadSeconds); var voice = new Random(7);
    var active = new List<(int Start, int End)>();
    while (at < x.Length)
    {
        int length = (int)(rate * (0.15 + 0.1 * voice.NextDouble())), end = Math.Min(x.Length, at + length);
        double pitch = 105 + 30 * voice.NextDouble();
        for (int i = at; i < end; i++)
        {
            double t = (double)(i - at) / length, envelope = Math.Sin(Math.PI * t);
            double sample = 0;
            for (int h = 1; h <= 30; h++) { double f = pitch * h; if (f > rate / 2.0) break; double formant = Math.Exp(-Math.Pow((f - 600) / 250, 2)) + 0.6 * Math.Exp(-Math.Pow((f - 1500) / 300, 2)) + 0.3 * Math.Exp(-Math.Pow((f - 2600) / 400, 2)) + 0.02; sample += formant * Math.Sin(2 * Math.PI * f * i / rate) / h; }
            x[i] = envelope * sample;
        }
        active.Add((at, end));
        at = end + (int)(rate * (0.06 + 0.08 * voice.NextDouble()));
    }
    double activeRms = Math.Sqrt(active.Sum(r => Enumerable.Range(r.Start, r.End - r.Start).Sum(i => x[i] * x[i])) / Math.Max(1, active.Sum(r => r.End - r.Start)));
    double gain = Math.Pow(10, activeDbfs / 20) / Math.Max(activeRms, 1e-12);
    return x.Select(v => (float)(v * gain)).ToArray();
}
const int Rate = 48000;
Check(!SpeechActivity.Detect(new float[Rate * 2], Rate), "digital silence is not speech");
foreach (double level in new[] { -50.0, -45, -40 })
foreach (double seconds in new[] { 1.0, 2.5, 4.0, 30.0 })
{
    var pink = PinkNoise((int)(Rate * seconds), level); var white = WhiteNoise((int)(Rate * seconds), level);
    Check(!SpeechActivity.Detect(pink, Rate) && !SpeechActivity.Detect(white, Rate), $"room noise at {level} dBFS for {seconds} s is not speech");
}
Check(Rms(PinkNoise(Rate * 2, -50)) > 0.002, "room noise at -50 dBFS was above the old whole-recording cut-off of 0.002");
var warmUp = new float[Rate * 2]; Array.Copy(PinkNoise(Rate * 2 - Rate * 15 / 100, -45), 0, warmUp, Rate * 15 / 100, Rate * 2 - Rate * 15 / 100);
Check(!SpeechActivity.Detect(warmUp, Rate), "warm-up zeros before room noise do not lower the floor");
var fadeIn = PinkNoise(Rate, -45); for (int i = 0; i < Rate / 10; i++) fadeIn[i] *= i / (Rate / 10f);
Check(!SpeechActivity.Detect(fadeIn, Rate), "a device fade-in before room noise is not speech");
var click = PinkNoise(Rate * 2, -50); for (int i = Rate; i < Rate + Rate * 6 / 100; i++) click[i] += 0.3f * MathF.Sin(i);
Check(!SpeechActivity.Detect(click, Rate), "one 60 ms click is not speech");
foreach (double level in new[] { -50.0, -45, -40 })
    Check(SpeechActivity.Detect(Mix(Syllables(Rate, 2.0, -22), PinkNoise(Rate * 2, level)), Rate), $"speech over room noise at {level} dBFS is speech");
Check(SpeechActivity.Detect(Mix(Syllables(Rate, 2.0, -28), PinkNoise(Rate * 2, -40)), Rate), "quiet speech 12 dB over -40 dBFS room noise is speech");
Check(SpeechActivity.Detect(Mix(Syllables(Rate, 2.0, -45), PinkNoise(Rate * 2, -70)), Rate), "far quiet speech in a quiet room is speech");
Check(SpeechActivity.Detect(Mix(Syllables(Rate, 2.0, -22, leadSeconds: 0), PinkNoise(Rate * 2, -45)), Rate), "speech that fills the whole recording is speech");
var word = new float[Rate]; Array.Copy(Syllables(Rate, 0.6, -22, leadSeconds: 0.3), word, (int)(Rate * 0.6));
Check(SpeechActivity.Detect(Mix(word, PinkNoise(Rate, -50)), Rate), "a single short word is speech");
Check(SpeechActivity.Detect(Mix(Syllables(16000, 2.0, -22), PinkNoise(32000, -45)), 16000), "speech at 16 kHz is speech");
float[] Interleave(float[] left, float[] right) { var x = new float[left.Length * 2]; for (int i = 0; i < left.Length; i++) { x[2 * i] = left[i]; x[2 * i + 1] = right[i]; } return x; }
bool DetectStereo(float[] interleaved) { var activity = new SpeechActivity(Rate, 2); foreach (var v in interleaved) activity.Add(v); return activity.HasSpeech; }
var stereoSpeech = Mix(Syllables(Rate, 2.0, -22), PinkNoise(Rate * 2, -45));
Check(DetectStereo(Interleave(stereoSpeech, stereoSpeech)) && DetectStereo(Interleave(stereoSpeech, new float[stereoSpeech.Length])), "stereo speech is speech, even with one dead channel");
Check(!DetectStereo(Interleave(PinkNoise(Rate * 2, -42), PinkNoise(Rate * 2, -42))), "stereo room noise is not speech");
var withNan = Mix(Syllables(Rate, 2.0, -22), PinkNoise(Rate * 2, -45)); withNan[100] = float.NaN; withNan[5000] = float.PositiveInfinity;
Check(SpeechActivity.Detect(withNan, Rate), "non-finite samples count as zero without breaking the check");
var oneSecond = new SpeechActivity(Rate, 2); for (int i = 0; i < Rate * 2; i++) oneSecond.Add(0);
Check(oneSecond.WindowCount == 33, "30 ms windows count frames, not interleaved samples");

// Speech audio conversion (parity P-F1, P-F8, P-F21): one sinc resample to 16 kHz mono for both engines and the speech check.
float[] Tone(double hz, int rate, double seconds, double amplitude = 0.5) { var x = new float[(int)(rate * seconds)]; for (int i = 0; i < x.Length; i++) x[i] = (float)(amplitude * Math.Sin(2 * Math.PI * hz * i / rate)); return x; }
// Level of one frequency over the middle second of a 16 kHz signal, in dB relative to amplitude 0.5.
double ToneDb(float[] x, double hz)
{
    int start = x.Length / 2 - 8000, length = 16000;
    double k = 2 * Math.PI * hz / 16000, c = 2 * Math.Cos(k), s1 = 0, s2 = 0;
    for (int i = start; i < start + length; i++) { double s0 = x[i] + c * s1 - s2; s2 = s1; s1 = s0; }
    double amplitude = Math.Sqrt(Math.Max(s1 * s1 + s2 * s2 - c * s1 * s2, 0)) / length * 2;
    return 20 * Math.Log10(Math.Max(amplitude, 1e-12) / 0.5);
}
foreach (int rate in new[] { 48000, 44100 })
{
    double worstPass = 0, worstAlias = -200;
    foreach (double hz in new[] { 100.0, 250, 500, 1000, 2000, 3000, 4000, 5000, 6000, 6500, 7000 })
        worstPass = Math.Max(worstPass, Math.Abs(ToneDb(SpeechAudio.Resample(Tone(hz, rate, 3), rate), hz)));
    foreach (double hz in new[] { 9000.0, 10000, 11000, 12000, 13000, 14000 })
        worstAlias = Math.Max(worstAlias, ToneDb(SpeechAudio.Resample(Tone(hz, rate, 3), rate), 16000 - hz));
    Check(worstPass <= 0.5, $"{rate} Hz to 16 kHz is within 0.5 dB from 100 Hz to 7 kHz (worst {worstPass:F2} dB)");
    Check(worstAlias < -40, $"{rate} Hz to 16 kHz keeps 9 to 14 kHz aliases below -40 dB (worst {worstAlias:F1} dB)");
    foreach (int length in new[] { rate * 3 / 2 + 7, 1, 0, rate / 100 })
        Check(SpeechAudio.Resample(new float[length], rate).Length == (int)Math.Round(length * 16000.0 / rate), $"{rate} Hz input of {length} samples gives the exact 16 kHz length");
}
var impulse = new float[48000]; impulse[24000] = 1;
var moved = SpeechAudio.Resample(impulse, 48000);
Check(Array.IndexOf(moved, moved.Max()) == 8000, "the resample adds no delay, so the last word is not cut");
Check(SpeechAudio.Resample(Tone(440, 16000, 1), 16000).SequenceEqual(Tone(440, 16000, 1)), "16 kHz input passes through unchanged");
float[] Channels(params float[][] each) { var x = new float[each[0].Length * each.Length]; for (int i = 0; i < each[0].Length; i++) for (int c = 0; c < each.Length; c++) x[i * each.Length + c] = each[c][i]; return x; }
var tone1k = Tone(1000, 48000, 2); var silent = new float[tone1k.Length];
Check(Math.Abs(ToneDb(SpeechAudio.Mono16k(tone1k, 48000, 1), 1000)) < 0.1, "mono input keeps its level");
Check(Math.Abs(ToneDb(SpeechAudio.Mono16k(Channels(tone1k, tone1k), 48000, 2), 1000)) < 0.1, "stereo with the same signal on both channels keeps its level");
Check(Math.Abs(ToneDb(SpeechAudio.Mono16k(Channels(tone1k, silent), 48000, 2), 1000) + 6.02) < 0.1, "stereo keeps the 0.5/0.5 mix");
Check(Math.Abs(ToneDb(SpeechAudio.Mono16k(Channels(tone1k, tone1k, tone1k, tone1k), 48000, 4), 1000)) < 0.1, "a 4-channel microphone is mixed to mono, not refused");
Check(Math.Abs(ToneDb(SpeechAudio.Mono16k(Channels(silent, tone1k, silent, silent), 48000, 4), 1000) + 12.04) < 0.1, "4 channels are averaged, one live input at a quarter level");
Check(SpeechAudio.Mono16k(Channels(tone1k, tone1k, tone1k, tone1k), 48000, 4).Length == 32000, "4-channel input gives the exact 16 kHz mono length");
var badSample = Channels(tone1k, tone1k); badSample[1001] = float.NaN; badSample[3001] = float.PositiveInfinity;
Check(SpeechAudio.Mono16k(badSample, 48000, 2).All(float.IsFinite), "non-finite samples never spread through the resampler");
byte[] Wav(NAudio.Wave.WaveFormat format, float[] interleaved)
{
    var memory = new MemoryStream();
    using (var writer = new NAudio.Wave.WaveFileWriter(memory, format)) foreach (var v in interleaved) writer.WriteSample(v);
    return memory.ToArray();
}
var fourWav = SpeechAudio.Mono16k(Wav(NAudio.Wave.WaveFormat.CreateIeeeFloatWaveFormat(48000, 4), Channels(silent, tone1k, silent, silent)));
Check(fourWav.Length == 32000 && Math.Abs(ToneDb(fourWav, 1000) + 12.04) < 0.1, "a 4-channel 48 kHz float WAV becomes 16 kHz mono at the right level");
var stereoWav = SpeechAudio.Mono16k(Wav(new NAudio.Wave.WaveFormat(44100, 16, 2), Channels(Tone(1000, 44100, 2), Tone(1000, 44100, 2))));
Check(stereoWav.Length == 32000 && Math.Abs(ToneDb(stereoWav, 1000)) < 0.1, "a 16-bit stereo 44.1 kHz WAV becomes 16 kHz mono at the right level");
// High hiss above 8 kHz is not what the engine hears, so it no longer raises the floor the speech check measures.
float[] Hiss(int n, double dbfs) { var noise = WhiteNoise(n, dbfs); var high = new float[n]; for (int i = 1; i < n - 1; i++) high[i] = (noise[i] - 0.5f * (noise[i - 1] + noise[i + 1])) * 0.8165f; return high; }
var hissy = Mix(Syllables(Rate, 2.0, -40), Hiss(Rate * 2, -30));
Check(SpeechActivity.Detect(SpeechAudio.Mono16k(hissy, Rate, 1), 16000), "soft speech under loud hiss above 8 kHz is speech on the 16 kHz mono the engine hears");

// Recording start (parity P-F6, UI-F2): the chime, panel and tray icon wait for live audio; 1.5 s shows the panel alone.
Check(DictationDeadlines.FirstAudio == TimeSpan.FromSeconds(1.5), "first audio deadline matches the Mac's 1.5 s");
var prompt = new RecordingStart();
Check(!prompt.Shown && !prompt.StopCue, "nothing is shown or chimed before live audio");
Check(prompt.AudioArrived() == (RecordingCue.Show | RecordingCue.Chime) && prompt.StopCue, "live audio plays the chime and shows recording");
Check(prompt.AudioArrived() == RecordingCue.None && prompt.DeadlinePassed() == RecordingCue.None, "live audio and the deadline act once");
var lateMic = new RecordingStart();
Check(lateMic.DeadlinePassed() == RecordingCue.Show && !lateMic.StopCue, "no live audio by the deadline shows the panel without the chime");
Check(lateMic.AudioArrived() == RecordingCue.Chime && lateMic.StopCue, "audio after the deadline still chimes, and then the stop cue plays");
var neverLive = new RecordingStart(); neverLive.DeadlinePassed();
Check(!neverLive.StopCue, "no stop cue when the start cue never played");
var live = new LiveAudio(48000, 2); int fired = 0;
for (int i = 0; i < 48000 * 2; i++) if (live.Add(0)) fired++;
Check(fired == 0 && !live.Heard, "zeroed packets (NAudio's silent flag) are not live audio");
for (int i = 0; i < 48000 * 2; i++) if (live.Add(1e-6f)) fired++;
Check(fired == 0, "a -120 dBFS hum is still digital silence");
var quiet = PinkNoise(48000 * 2, -70); int at = -1; live = new LiveAudio(48000, 2);
for (int i = 0; i < quiet.Length; i++) if (live.Add(quiet[i])) { fired++; if (at < 0) at = i; }
Check(fired == 1 && live.Heard && at == 48 * 30 * 2 - 1, "the first 30 ms window of real room sound is live, once");
Console.WriteLine($"{tests} checks passed.");
return 0;

sealed class BytesHandler(byte[] bytes) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) });
    }
}

sealed class InlineProgress(Action<double> action) : IProgress<double> { public void Report(double value) => action(value); }

sealed class RoutesHandler(Dictionary<string, byte[]> routes) : HttpMessageHandler
{
    public int Requests;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Interlocked.Increment(ref Requests);
        return Task.FromResult(routes.TryGetValue(request.RequestUri!.AbsolutePath, out var bytes)
            ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) }
            : new HttpResponseMessage(HttpStatusCode.NotFound));
    }
}
