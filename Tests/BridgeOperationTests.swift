import Foundation

@main struct BridgeOperationTests {
    static func main() async {
        let node = CommandLine.arguments[1], fixture = CommandLine.arguments[2]
        var checks = 0
        func check(_ condition:Bool,_ name:String) { checks += 1; if !condition { fatalError(name) } }
        let selected = " \tCafé 日本語\r\n "
        let rewrite = BridgeRequest(operation:"rewrite",selection:selected,instruction:"Use a shorter sentence")
        for scenario in ["error","fallback","wrong-operation","wrong-version","malformed","control","whitespace","extra-whitespace","trimmed","nonzero","hang"] {
            let service = BridgeOperations(node:node,bridge:fixture,config:scenario,timeout:1)
            let result = await service.perform(rewrite)
            check(result.insertionText(raw:"RAW INSTRUCTION",isRewrite:true) == nil,"\(scenario) cannot authorize any rewrite")
        }
        let missing = await BridgeOperations(node:"/missing/sona-node",bridge:fixture).perform(rewrite)
        check(missing.insertionText(raw:"RAW",isRewrite:true) == nil,"missing executable leaves selection unchanged")
        let success = await BridgeOperations(node:node,bridge:fixture,config:"ok").perform(rewrite)
        check(success.insertionText(raw:"ignored",isRewrite:true) == selected,"complete replacement retains exact whitespace and Unicode")
        let raw = "  Keep my raw words.\n"
        let dictation = BridgeRequest(operation:"dictate",transcript:raw,mode:"prose",cleanupEnabled:true)
        let fallback = await BridgeOperations(node:node,bridge:fixture,config:"error").perform(dictation)
        check(fallback.insertionText(raw:raw,isRewrite:false) == raw,"dictation error retains exact raw independently of bridge")
        let snippet = BridgeRequest(operation:"snippet_assist",context:"Regards, Sona")
        let proposals = await BridgeOperations(node:node,bridge:fixture,config:"snippet").perform(snippet)
        check(proposals.snippets == [.init(trigger:"my signoff",expansion:"Regards, Sona")],"explicit context proposal parsed")
        let invented = await BridgeOperations(node:node,bridge:fixture,config:"invented").perform(snippet)
        check(invented.status == "error","unsupplied personal expansion refused")
        let assistant = BridgeRequest(operation:"assistant",instruction:"What is shown?",options:.init(provider:"fixture",model:"sample",effort:"low"),intent:"screen_ask",images:[.init(mimeType:"image/jpeg",dataBase64:"AAA=")])
        let contextual = BridgeRequest(operation:"assistant",instruction:"Open the page",intent:"screen_ask",
            assistantContext:.init(appName:"Fixture Browser"))
        let encoded = try! JSONSerialization.jsonObject(with:JSONEncoder().encode(contextual)) as! [String:Any]
        check((encoded["context"] as? [String:Any])?["appName"] as? String == "Fixture Browser","current target app identity reaches the shared bridge")
        check((encoded["context"] as? [String:Any])?.count == 1, "screen questions send no installed-app inventory")
        let catalog = await BridgeOperations(node:node,bridge:fixture,config:"catalog").catalog()
        check(catalog?.selected == .init(provider:"fixture",model:"sample",effort:"low"),"catalog resolves provider choices without native model names")
        let noEffort = await BridgeOperations(node:node,bridge:fixture,config:"catalog-no-effort").catalog()
        check(noEffort?.selected?.effort == "default" && noEffort?.providers.first?.models.first?.efforts == [],"models without reasoning levels do not invalidate the catalog")
        let unresolved = await BridgeOperations(node:node,bridge:fixture,config:"catalog-unresolved").catalog()
        check(unresolved != nil && unresolved?.selected == nil,"unavailable saved choice still exposes catalog without selecting another model")
        let answer = await BridgeOperations(node:node,bridge:fixture,config:"assistant-ok").perform(assistant)
        check(answer.kind == "answer" && answer.text == "Fixture answer","answer stays typed as panel output")
        check(answer.insertionText(raw:"QUESTION",isRewrite:false) == nil && answer.insertionText(raw:"QUESTION",isRewrite:true) == nil,"a screen answer is never an insertion result")
        for bad in ["assistant-wrong-kind","assistant-invalid-path","assistant-error","assistant-blender","assistant-actions","assistant-answer-actions","assistant-answer-artifacts","assistant-answer-malformed-actions","assistant-answer-malformed-artifacts"] + ["click","type","key","scroll","open_app","open_url","wait"].map({ "assistant-action-" + $0 }) {
            let result = await BridgeOperations(node:node,bridge:fixture,config:bad).perform(assistant)
            check(result.status == "error" && result.actions == nil && result.artifacts == nil && result.insertionText(raw:"QUESTION",isRewrite:true) == nil,"screen answers reject executable payloads without inserting the question")
        }
        let timeout = await BridgeOperations(node:node,bridge:fixture,config:"assistant-timeout").perform(assistant)
        check(timeout.status == "error" && timeout.assistantFailureCode == "timeout" && timeout.actions == nil,
              "typed timeout remains a connection failure, not a successful action or blanket capability refusal")
        let privateReason = await BridgeOperations(node:node,bridge:fixture,config:"assistant-private-reason").perform(assistant)
        check(privateReason.assistantFailureCode == "unavailable" && !privateReason.assistantFailureMessage.contains("PRIVATE"),
              "unknown provider reason cannot leak content into diagnostics or panel error")
        for (reason, detail) in [("invalid_assistant_response","response_format"),
                                ("invalid_assistant_actions","action_format"),
                                ("incomplete_response","incomplete"),
                                ("invalid_response","transport_format"),
                                ("response_too_large","size_limit")] {
            let rejected = BridgeResult(version:1,operation:"assistant",status:"error",text:nil,snippets:nil,reason:reason)
            check(rejected.assistantFailureCode == "invalid_response" && rejected.assistantFailureDetail == detail,
                  "format diagnosis has a fixed subcode and authorizes no action")
            check(rejected.actions == nil && rejected.insertionText(raw:"INSTRUCTION",isRewrite:true) == nil,
                  "diagnostic detail cannot turn failure into an edit")
        }
        check(privateReason.assistantFailureDetail == "unavailable", "unrecognized reason is never copied into diagnostic detail")
        for (reason, code, phrase) in [
            ("authentication_failed","authentication_failed","sign in again"),
            ("provider_access_denied","access_denied","does not allow"),
            ("billing_error","billing_error","billing problem"),
            ("rate_limited","rate_limited","usage or rate limit"),
            ("provider_request_rejected","provider_rejected","provider rejected"),
            ("provider_unavailable","provider_unavailable","temporarily unavailable")] {
            let rejected = BridgeResult(version:1,operation:"assistant",status:"error",text:nil,snippets:nil,reason:reason)
            check(rejected.assistantFailureCode == code && rejected.assistantFailureMessage.contains(phrase),
                  "structured provider failure has a specific fixed explanation")
            check(rejected.actions == nil && rejected.insertionText(raw:"INSTRUCTION",isRewrite:true) == nil,
                  "provider failure cannot authorize an action or replacement")
        }
        for reason in ["provider_error","cli_failed","cli_closed","provider_tool_or_error","launch_failed","cli_launch_failed","cli_stdin_failed"] {
            let rejected = BridgeResult(version:1,operation:"assistant",status:"error",text:nil,snippets:nil,reason:reason)
            check(rejected.assistantFailureCode == "connection_failed" && rejected.assistantFailureDetail == reason,
                  "connection diagnostics preserve only fixed transport subcodes")
        }

        for duration in [250, 750, 1500] {
            check(BridgeAction(type:"wait",milliseconds:duration).isValid, "bounded wait is a valid native proposal")
        }
        for duration in [-1, 0, 249, 1501, Int.max] {
            check(!BridgeAction(type:"wait",milliseconds:duration).isValid, "native boundary rejects invalid wait duration")
        }
        check(!BridgeAction(type:"wait").isValid, "wait requires a duration")
        check(!BridgeAction(type:"wait",text:"unexpected input",milliseconds:750).isValid, "wait cannot carry input to type")
        for raw in [#"{"type":"wait","milliseconds":750.5}"#, #"{"type":"wait","milliseconds":"750"}"#, #"{"type":"wait","milliseconds":true}"#] {
            check((try? JSONDecoder().decode(BridgeAction.self,from:Data(raw.utf8))) == nil, "wait duration uses a typed integer")
        }
        print("PASS: \(checks) real local typed-bridge process, timeout, failure/no-rewrite and whitespace checks")
    }
}
