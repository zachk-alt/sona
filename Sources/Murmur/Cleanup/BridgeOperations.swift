import Foundation

struct BridgeRequest: Encodable {
    var version = 1
    let operation: String
    var transcript: String? = nil
    var mode: String? = nil
    var cleanupEnabled: Bool? = nil
    var selection: String? = nil
    var instruction: String? = nil
    var context: String? = nil
    var profile: String? = nil
    var options: AssistantChoice? = nil
    var intent: String? = nil
    var images: [BridgeImage]? = nil
    var messages: [AssistantMessage]? = nil
    var assistantContext: BridgeAssistantContext? = nil
    enum CodingKeys:String,CodingKey { case version,operation,transcript,mode,cleanupEnabled,selection,instruction,context,profile,options,intent,images,messages }
    func encode(to encoder:Encoder) throws {
        var c = encoder.container(keyedBy:CodingKeys.self)
        try c.encode(version,forKey:.version); try c.encode(operation,forKey:.operation)
        try c.encodeIfPresent(transcript,forKey:.transcript); try c.encodeIfPresent(mode,forKey:.mode)
        try c.encodeIfPresent(cleanupEnabled,forKey:.cleanupEnabled); try c.encodeIfPresent(selection,forKey:.selection)
        try c.encodeIfPresent(instruction,forKey:.instruction)
        if operation == "assistant" { try c.encodeIfPresent(assistantContext,forKey:.context) }
        else { try c.encodeIfPresent(context,forKey:.context) }
        try c.encodeIfPresent(profile,forKey:.profile); try c.encodeIfPresent(options,forKey:.options)
        try c.encodeIfPresent(intent,forKey:.intent); try c.encodeIfPresent(images,forKey:.images)
        try c.encodeIfPresent(messages,forKey:.messages)
    }
}
struct BridgeAssistantContext: Encodable {
    var appName: String? = nil
}
struct BridgeResult: Decodable {
    let version: Int
    let operation: String
    let status: String
    let text: String?
    let snippets: [Snippet]?
    let reason: String?
    var kind: String? = nil
    var artifacts: BridgeArtifacts? = nil
    var actions:[BridgeAction]? = nil
    func insertionText(raw:String,isRewrite:Bool) -> String? {
        guard operation != "assistant" else { return nil }
        if isRewrite { return status == "ok" ? text : nil }
        return status == "ok" ? (text ?? raw) : raw
    }
    static func failed(_ operation: String) -> Self { .init(version:1,operation:operation,status:"error",text:nil,snippets:nil,reason:"unavailable") }
    // Only fixed categories enter diagnostics. Provider text and unknown reason
    // strings must never become a local transcript or credential log.
    var assistantFailureCode: String {
        switch reason {
        case "timeout", "blender_timeout": return "timeout"
        case "cancelled": return "cancelled"
        case "assistant_model_unavailable", "unexpected_model", "model_changed": return "model_unavailable"
        case "assistant_effort_unavailable": return "effort_unavailable"
        case "assistant_vision_unavailable": return "vision_unavailable"
        case "cli_not_found", "no_supported_cli", "codex_native_not_found": return "cli_missing"
        case "ai_disabled": return "disabled"
        case "assistant_provider_not_reviewed", "local_history_not_allowed": return "connection_unsupported"
        case "invalid_assistant_response", "incomplete_response", "invalid_response", "invalid_assistant_actions", "response_too_large": return "invalid_response"
        case "images_too_large", "invalid_image", "invalid_images", "input_too_large", "assistant_history_too_large": return "request_rejected"
        case "authentication_failed": return "authentication_failed"
        case "provider_access_denied": return "access_denied"
        case "billing_error": return "billing_error"
        case "rate_limited": return "rate_limited"
        case "provider_request_rejected": return "provider_rejected"
        case "provider_unavailable": return "provider_unavailable"
        case "provider_error", "cli_failed", "cli_closed", "provider_tool_or_error", "launch_failed", "cli_launch_failed", "cli_stdin_failed": return "connection_failed"
        default: return "unavailable"
        }
    }
    // Split format failures without logging arbitrary bridge/provider text.
    var assistantFailureDetail: String {
        switch reason {
        case "invalid_assistant_response": return "response_format"
        case "invalid_assistant_actions": return "action_format"
        case "incomplete_response": return "incomplete"
        case "invalid_response": return "transport_format"
        case "response_too_large": return "size_limit"
        case "provider_error", "cli_failed", "cli_closed", "provider_tool_or_error", "launch_failed", "cli_launch_failed", "cli_stdin_failed": return reason!
        default: return assistantFailureCode
        }
    }
    var assistantFailureMessage: String {
        switch assistantFailureCode {
        case "timeout": return "The selected AI took too long to respond to this step."
        case "cancelled": return "This step was cancelled."
        case "model_unavailable": return "The selected Assistant model is unavailable. Check the model in Sona's menu."
        case "effort_unavailable": return "The selected reasoning level is unavailable for this model. Check the Assistant settings."
        case "vision_unavailable": return "The selected Assistant model does not support screen images. Choose an image-capable model."
        case "cli_missing": return "Sona could not find the CLI for the selected Assistant connection."
        case "disabled": return "The Assistant AI connection is turned off."
        case "connection_unsupported": return "The selected connection does not support Sona's Assistant requests."
        case "invalid_response": return "The AI returned an incomplete or unusable response for this step."
        case "request_rejected": return "The screen request could not be sent in its current form."
        case "authentication_failed": return "The AI connection needs you to sign in again through its CLI."
        case "access_denied": return "The AI account does not allow this request. Check access in the selected CLI."
        case "billing_error": return "The AI provider reported a billing problem. Check the account used by its CLI."
        case "rate_limited": return "The AI provider has reached a usage or rate limit. Try again when access resets."
        case "provider_rejected": return "The AI provider rejected this request. Try a fresh Option request; if it repeats, check the selected model."
        case "provider_unavailable": return "The AI provider is temporarily unavailable. Try the Option request again shortly."
        case "connection_failed": return "The AI connection failed while processing this step."
        default: return "The AI connection could not finish this step."
        }
    }
}
/// One typed bridge route for dictation, rewriting and explicit setup assistance.
final class BridgeOperations {
    private let node: String?
    private let bridge: String
    private let config: String
    private let timeout: Double
    private let lock = NSLock()
    private var active: [UUID: CleanupBridgeRun] = [:]
    init(node: String?, bridge: String, config: String = Config.configURL.path, timeout: Double = 14) {
        self.node = node; self.bridge = bridge; self.config = config; self.timeout = min(35,max(1,timeout))
    }
    func perform(_ request: BridgeRequest,assistantTimeout:Double? = nil,outerTimeout:Double? = nil) async -> BridgeResult {
        let extended = request.operation == "assistant" || request.profile == "assistant"
        guard let node, let data = try? JSONEncoder().encode(request), data.count <= (extended ? 3*1024*1024 : 160*1024),
              let input = String(data:data,encoding:.utf8) else { return .failed(request.operation) }
        let run = CleanupBridgeRun(nodePath:node,arguments:[bridge,"--request","--config",config],input:input,timeout:request.operation == "assistant" ? min(185,max(0.1,outerTimeout ?? 185)) : (extended ? min(185,max(1,(assistantTimeout ?? 120)+3)) : timeout))
        let id = UUID(); lock.withLock { active[id] = run }
        let output = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos:.userInitiated).async { continuation.resume(returning:run.perform(validateGrowth:false)) }
            }
        }, onCancel:{ run.cancel() })
        _ = lock.withLock { active.removeValue(forKey:id) }
        guard !Task.isCancelled, let resultData = output.data(using:.utf8),
              let result = try? JSONDecoder().decode(BridgeResult.self,from:resultData),
              result.version == 1, result.operation == request.operation,
              ["ok","fallback","error","needs_input"].contains(result.status) else { return .failed(request.operation) }
        if request.operation == "assistant", result.status == "ok" {
            // Screen questions are read-only, even with an older or malformed bridge.
            guard result.kind == "answer", result.text != nil,
                  result.actions == nil, result.artifacts == nil else { return .failed(request.operation) }
        }
        if result.status == "ok" {
            if request.operation == "snippet_assist" {
                guard let snippets = result.snippets, snippets.count <= 128, snippets.allSatisfy({ $0.isValid && (request.context?.contains($0.expansion) == true) }) else { return .failed(request.operation) }
            } else {
                guard let text = result.text, !text.isEmpty, text.utf8.count <= 64 * 1024, !text.unicodeScalars.contains(where: {
                    ($0.value < 32 && ![9,10,13].contains($0.value)) || (127...159).contains($0.value)
                }) else { return .failed(request.operation) }
            }
        }
        if request.operation == "rewrite", result.status == "ok", let selected = request.selection, let text = result.text {
            func whitespace(_ scalar:Unicode.Scalar) -> Bool { scalar.properties.isWhitespace || scalar.value == 0xFEFF }
            guard text.unicodeScalars.contains(where:{ !whitespace($0) }) else { return .failed(request.operation) }
            let leading = String(String.UnicodeScalarView(selected.unicodeScalars.prefix(while:whitespace)))
            let trailing = String(String.UnicodeScalarView(selected.unicodeScalars.reversed().prefix(while:whitespace).reversed()))
            let outputLeading = String(String.UnicodeScalarView(text.unicodeScalars.prefix(while:whitespace)))
            let outputTrailing = String(String.UnicodeScalarView(text.unicodeScalars.reversed().prefix(while:whitespace).reversed()))
            guard outputLeading == leading, outputTrailing == trailing else { return .failed(request.operation) }
        }
        return result
    }
    func catalog() async -> BridgeCatalog? {
        guard let node else { return nil }
        let run = CleanupBridgeRun(nodePath:node,arguments:[bridge,"--catalog","--config",config],input:"{}",timeout:15)
        let id = UUID(); lock.withLock { active[id] = run }
        let output = await withTaskCancellationHandler(operation:{
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos:.userInitiated).async { continuation.resume(returning:run.perform(validateGrowth:false)) }
            }
        },onCancel:{ run.cancel() })
        _ = lock.withLock { active.removeValue(forKey:id) }
        guard !Task.isCancelled, let data = output.data(using:.utf8),
              let catalog = try? JSONDecoder().decode(BridgeCatalog.self,from:data), catalog.isValid else { return nil }
        return catalog
    }
    func cancel() { lock.lock(); let runs = Array(active.values); lock.unlock(); runs.forEach { $0.cancel() } }
}

struct BridgeImage: Encodable { let mimeType:String; let dataBase64:String }
struct BridgeArtifacts: Decodable {
    let blendPath:String
    let previewPath:String
    var isValid: Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Sona/Creations").standardizedFileURL.resolvingSymlinksInPath()
        let blend = URL(fileURLWithPath:blendPath).standardizedFileURL.resolvingSymlinksInPath()
        let preview = URL(fileURLWithPath:previewPath).standardizedFileURL.resolvingSymlinksInPath()
        let parent = blend.deletingLastPathComponent()
        return [blendPath,previewPath].allSatisfy { $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") }
            && blend.lastPathComponent == "Scene.blend" && preview.lastPathComponent == "Preview.png"
            && parent.path == preview.deletingLastPathComponent().path && parent.lastPathComponent.hasPrefix("Scene-")
            && parent.deletingLastPathComponent().path == root.path
    }
}
struct BridgeCatalog: Decodable {
    struct Provider: Decodable {
        let id:String; let label:String; let available:Bool; let reason:String?
        let models:[Model]
    }
    struct Model: Decodable {
        let id:String; let label:String; let vision:Bool
        let efforts:[String]; let defaultEffort:String; let operations:[String]
    }
    let version:Int; let operation:String; let status:String
    let selected:AssistantChoice?
    let reason:String?
    let providers:[Provider]
    var isValid:Bool {
        version == 1 && operation == "catalog" && status == "ok" && providers.count <= 32
            && providers.allSatisfy { !$0.id.isEmpty && $0.label.utf8.count <= 200 && $0.models.count <= 128
                && $0.models.allSatisfy { !$0.id.isEmpty && $0.label.utf8.count <= 200 && $0.efforts.count <= 16
                    && ($0.efforts.isEmpty ? $0.defaultEffort == "default" : $0.efforts.contains($0.defaultEffort)) } }
    }
}

struct BridgeAction: Codable {
    let type:String
    var x:Double? = nil
    var y:Double? = nil
    var text:String? = nil
    var key:String? = nil
    var direction:String? = nil
    var appId:String? = nil
    var url:String? = nil
    var amount:Int? = nil
    var milliseconds:Int? = nil
    var requiresConfirmation:Bool? = nil
    var isValid:Bool {
        switch type {
        case "click": return x.map { $0.isFinite && (0...1).contains($0) } == true && y.map { $0.isFinite && (0...1).contains($0) } == true
        case "type": return text.map { !$0.isEmpty && $0.utf8.count <= 8192 && !$0.unicodeScalars.contains { ($0.value < 32 && ![9,10,13].contains($0.value)) || (127...159).contains($0.value) } } == true
        case "key": return key.map { !$0.isEmpty && $0.utf8.count <= 40 } == true
        case "scroll": return ["up","down"].contains(direction ?? "") && (1...5).contains(amount ?? 0)
        case "wait": return milliseconds.map { (250...1500).contains($0) } == true
            && x == nil && y == nil && text == nil && key == nil && direction == nil && appId == nil && url == nil && amount == nil
        case "open_app": return appId.map { !$0.isEmpty && $0.utf8.count <= 200 } == true
        case "open_url": return url.flatMap(URL.init(string:)).map { ["https","http"].contains($0.scheme ?? "") && $0.host != nil && $0.user == nil && $0.password == nil } == true
        default: return false
        }
    }
}
