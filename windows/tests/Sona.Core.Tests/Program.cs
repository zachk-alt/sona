using System.Diagnostics;
using System.Net;
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
