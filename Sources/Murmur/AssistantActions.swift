import AppKit
import ApplicationServices

struct AssistantAvailableApp: Encodable { let id: String; let label: String }
struct AssistantActionReceipt { let target: AssistantWindowReference; let message: String }
enum AssistantActionError: LocalizedError {
    case changed, unsupported, protected, launchTimedOut, openedWindowUnavailable, confirmationRequired(String)
    var errorDescription: String? {
        switch self {
        case .changed: return "The window or your activity changed. I stopped before the next action."
        case .launchTimedOut: return "The app-opening request did not finish in time. No further action will run."
        case .openedWindowUnavailable: return "The app was opened, but its foreground window was not ready. I stopped without opening another app. Invoke Assistant again when it is ready."
        case .unsupported: return "This control does not support a verified action. You can complete this step manually."
        case .protected: return "Sona cannot control terminals, password fields or system permission dialogs."
        case .confirmationRequired(let detail): return detail
        }
    }
}

/// Fixed native actions on the explicitly captured app. No command interpreter,
/// arbitrary paths, downloaded scripts, or provider-supplied executable arguments.
@MainActor
final class AssistantActions {
    private var monitor: Any?
    private var changed = false
    private var generation = UUID()
    private let sourceTag = Int64.random(in: 1...Int64.max)
    private var armed = false
    private let cursor = AssistantCursor()
    private let actionNamesReader: ((AXUIElement) -> [String])?
    private var pendingLaunch: AssistantCaptureDeadline<NSRunningApplication>?
    private let accessibilityPreparation = AssistantAccessibilityPreparation()

    init(actionNamesReader: ((AXUIElement) -> [String])? = nil) {
        self.actionNamesReader = actionNamesReader
    }

    func begin(target: AssistantWindowReference, ignoringKey: ((NSEvent) -> Bool)? = nil) {
        cancel(); changed = false; armed = target.remainsForeground()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown,.leftMouseDown,.rightMouseDown,.otherMouseDown,.scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.cgEvent?.getIntegerValueField(.eventSourceUserData) != self.sourceTag, !TextInserter.isOwnPasteEvent(event) else { return }
                if event.type == .keyDown && ignoringKey?(event) == true { return }
                self.changed = true
                self.cursor.hide()
                self.pendingLaunch?.cancel()
            }
        }
    }
    func cancel() {
        generation = UUID(); armed = false
        accessibilityPreparation.cancel()
        pendingLaunch?.cancel(); pendingLaunch = nil
        cursor.hide()
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    }
    func permitsRequest(_ target: AssistantWindowReference) -> Bool {
        armed && !changed && !Task.isCancelled && target.remainsForeground()
    }
    private func check(_ target: AssistantWindowReference) throws {
        guard armed, !changed, !Task.isCancelled, target.remainsForeground() else { throw AssistantActionError.changed }
        guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: target.pid),
              !Self.protectedApps.contains(app.bundleIdentifier ?? "") else {
            throw AssistantActionError.protected
        }
    }
    private static let protectedApps: Set<String> = [
        "com.apple.SecurityAgent", "com.apple.systempreferences", "com.apple.loginwindow", "com.apple.Passwords",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable"
    ]
    static func availableApps() -> [AssistantAvailableApp] {
        applicationURLs().compactMap { id,url in
            let label = (Bundle(url:url)?.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return AssistantAvailableApp(id:id,label:String(label.prefix(100)))
        }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }.prefix(64).map { $0 }
    }
    private static func applicationURLs() -> [String:URL] {
        var found:[String:URL] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, let url = app.bundleURL, app.activationPolicy == .regular { found[id] = url }
        }
        for folder in [URL(fileURLWithPath:"/Applications"),URL(fileURLWithPath:"/System/Applications"),FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            guard let entries = try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil,options:.skipsHiddenFiles) else { continue }
            for entry in entries.prefix(256) where entry.pathExtension == "app" {
                if let id = Bundle(url:entry)?.bundleIdentifier { found[id] = entry }
            }
        }
        found.removeValue(forKey:"dev.murmur.Murmur")
        for id in protectedApps { found.removeValue(forKey:id) }
        return found
    }

    func execute(_ action: BridgeAction, target: AssistantWindowReference, approved: Bool = false) async throws -> AssistantActionReceipt {
        let epoch = generation
        defer { if epoch == generation { cursor.hide() } }
        try check(target)
        if action.requiresConfirmation == true && !approved {
            throw AssistantActionError.confirmationRequired("Approve this requested action before Sona continues.")
        }
        var expectedPID = target.pid
        var openedApplication = false
        switch action.type {
        case "wait":
            guard action.isValid, let milliseconds = action.milliseconds else { throw AssistantActionError.unsupported }
            try await AssistantWait.run(milliseconds:milliseconds) {
                guard epoch == self.generation else { throw AssistantActionError.changed }
                try self.check(target)
            }
        case "click":
            guard let x = action.x, let y = action.y, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
                  let frame = target.frame, frame.width > 1, frame.height > 1 else { throw AssistantActionError.unsupported }
            try await prepareAccessibility(target,epoch:epoch)
            let point = CGPoint(x:frame.minX + x*frame.width,y:frame.minY + y*frame.height)
            let destination = try clickTarget(at:point,target:target,approved:approved,phase:.initial)
            try await cursor.move(to:point)
            guard epoch == generation else { throw AssistantActionError.changed }
            try check(target)
            // A page can change beneath the marker while it moves. Re-hit-test
            // and require the same native control before applying anything.
            let verified = try clickTarget(at:point,target:target,approved:approved,phase:.recheck)
            guard verified.kind == destination.kind, CFEqual(verified.element,destination.element) else { throw AssistantActionError.changed }
            try check(target)
            // Search reads may use only their remaining budget. Restore the
            // established action timeout before dispatching the semantic action.
            AXUIElementSetMessagingTimeout(verified.element,0.1)
            let result = verified.kind == .press
                ? AXUIElementPerformAction(verified.element,kAXPressAction as CFString)
                : AXUIElementSetAttributeValue(verified.element,kAXFocusedAttribute as CFString,kCFBooleanTrue)
            guard result == .success else {
                Log.write(AssistantClickDiagnostics.line(reason:verified.kind == .press ? .pressFailed : .focusFailed,
                    phase:.apply,depth:verified.depth,role:verified.role,axResult:result.rawValue))
                throw AssistantActionError.unsupported
            }
            cursor.applied()
        case "type":
            guard let text = action.text, !text.isEmpty, text.utf8.count <= 8192,
                  !text.unicodeScalars.contains(where:{ ($0.value < 32 && ![9,10,13].contains($0.value)) || (127...159).contains($0.value) }) else { throw AssistantActionError.unsupported }
            let field = try editableField(target)
            guard let selected = SelectionSnapshot.read(field), let destination = FocusedElement.captureTarget(),
                  destination.pid == target.pid, destination.element != nil else { throw AssistantActionError.unsupported }
            try check(target)
            let method = TextInserter.insert(text,into:destination,validateSelection:{
                self.armed && !self.changed && target.remainsForeground() && SelectionSnapshot.read(field) == selected
            })
            guard method == .paste else { throw AssistantActionError.unsupported }
        case "key":
            guard let key = action.key else { throw AssistantActionError.unsupported }
            let map:[String:(CGKeyCode,CGEventFlags)] = ["enter":(36,[]),"shift+enter":(36,.maskShift),"tab":(48,[]),"escape":(53,[]),
                "backspace":(51,[]),"delete":(117,[]),"left":(123,[]),"right":(124,[]),"up":(126,[]),"down":(125,[]),"cmd+a":(0,.maskCommand),"cmd+z":(6,.maskCommand)]
            guard let (code,flags) = map[key] else { throw AssistantActionError.unsupported }
            if ["enter","shift+enter"].contains(key) && !approved { throw AssistantActionError.confirmationRequired("Enter can submit or send in this app. Approve this keypress to continue.") }
            if ["backspace","delete","shift+enter"].contains(key) { _ = try editableField(target) }
            try check(target)
            for down in [true,false] {
                guard let event = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down) else { throw AssistantActionError.unsupported }
                event.flags = flags; event.setIntegerValueField(.eventSourceUserData,value:sourceTag); event.postToPid(target.pid)
            }
        case "scroll":
            guard let direction = action.direction, ["up","down"].contains(direction), let amount = action.amount, (1...5).contains(amount),
                  let frame = target.frame, let event = CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:Int32(amount*150*(direction == "up" ? 1 : -1)),wheel2:0,wheel3:0) else { throw AssistantActionError.unsupported }
            event.location = CGPoint(x:frame.midX,y:frame.midY); event.setIntegerValueField(.eventSourceUserData,value:sourceTag); event.postToPid(target.pid)
        case "open_app":
            guard let id = action.appId, let url = Self.applicationURLs()[id] else { throw AssistantActionError.unsupported }
            let app = try await openApplication(at:url,urls:nil,epoch:epoch)
            expectedPID = app.processIdentifier; openedApplication = true
        case "open_url":
            guard let raw = action.url, raw.utf8.count <= 2048, let url = URL(string:raw), ["https","http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else { throw AssistantActionError.unsupported }
            let application = try Self.applicationForURL(url,target:target)
            let app = try await openApplication(at:application,urls:[url],epoch:epoch)
            expectedPID = app.processIdentifier; openedApplication = true
        default: throw AssistantActionError.unsupported
        }
        let next:AssistantWindowReference
        if openedApplication {
            next = try await settleOpenedWindow(original:target,expectedPID:expectedPID,epoch:epoch)
            try await prepareAccessibility(next,epoch:epoch)
        } else if action.type == "wait" {
            guard epoch == generation else { throw AssistantActionError.changed }
            try check(target)
            next = target
        } else {
            try await Task.sleep(for:.milliseconds(250))
            guard epoch == generation, !changed, !Task.isCancelled,
                  let current = AssistantWindowReference.invocation(), current.pid == expectedPID else { throw AssistantActionError.changed }
            next = current
        }
        return .init(target:next,message:"Completed one \(action.type) action. Inspect the new screenshot before deciding the next step.")
    }
    private func prepareAccessibility(_ target:AssistantWindowReference,epoch:UUID) async throws {
        do {
            try await accessibilityPreparation.prepare(pid:target.pid,validate:{
                guard epoch == self.generation else { throw AssistantActionError.changed }
                try self.check(target)
            },enable:{
                let app = AXUIElementCreateApplication(target.pid)
                AXUIElementSetMessagingTimeout(app,0.1)
                // Advisory for apps that support it, as in FocusedElement.
                // Unsupported attributes do not replace actual AX validation.
                AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue)
            })
        } catch is CancellationError { throw AssistantActionError.changed }
    }
    private func openApplication(at application:URL,urls:[URL]?,epoch:UUID) async throws -> NSRunningApplication {
        let waiter = AssistantCaptureDeadline<NSRunningApplication>()
        pendingLaunch = waiter
        defer { if pendingLaunch === waiter { pendingLaunch = nil } }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true; config.promptsUserIfNeeded = false
        config.addsToRecentItems = false; config.allowsRunningApplicationSubstitution = false
        do {
            let opened = try await waiter.wait(seconds:5) { completion in
                AssistantLaunchDispatch.enqueue(waiter:waiter,isCurrent:{ [weak self] in
                    guard let self else { return false }
                    return epoch == self.generation && self.armed && !self.changed && !Task.isCancelled
                },submit:{
                    let didOpen: @Sendable (NSRunningApplication?,Error?) -> Void = { app,error in
                        if let app { completion(.success(app)) }
                        else { completion(.failure(error ?? AssistantActionError.unsupported)) }
                    }
                    if let urls {
                        NSWorkspace.shared.open(urls,withApplicationAt:application,configuration:config,completionHandler:didOpen)
                    } else {
                        NSWorkspace.shared.openApplication(at:application,configuration:config,completionHandler:didOpen)
                    }
                })
            }
            guard epoch == generation, armed, !changed, !Task.isCancelled else { throw AssistantActionError.changed }
            return opened
        } catch {
            guard epoch == generation, armed, !changed, !Task.isCancelled else { throw AssistantActionError.changed }
            if error is CancellationError { throw AssistantActionError.launchTimedOut }
            throw error
        }
    }
    private enum ClickKind { case press, focus }
    private struct ClickTarget { let element:AXUIElement; let kind:ClickKind; let role:String; let depth:Int }
    private func clickTarget(at point:CGPoint,target:AssistantWindowReference,approved:Bool,phase:AssistantClickDiagnostics.Phase) throws -> ClickTarget {
        try check(target)
        let budget=AssistantSemanticSearch.Budget()
        var lastRole:String?, lastDepth=0, lastAXResult:Int32?
        func prepare(_ element:AXUIElement) throws {
            AXUIElementSetMessagingTimeout(element,Float(try budget.readTimeout()))
        }
        func value(_ element:AXUIElement,_ attribute:String) throws -> CFTypeRef? {
            try prepare(element)
            var result:CFTypeRef?
            let status=AXUIElementCopyAttributeValue(element,attribute as CFString,&result)
            try budget.check()
            switch AssistantAXReadPolicy.disposition(status) {
            case .value:
                guard let result else { lastAXResult=status.rawValue; throw AssistantSemanticSearch.Failure.metadata }
                return result
            case .absent: return nil
            case .failed: lastAXResult=status.rawValue; throw AssistantSemanticSearch.Failure.metadata
            }
        }
        func element(_ item:AXUIElement,_ attribute:String) throws -> AXUIElement? {
            guard let result=try value(item,attribute) else { return nil }
            guard CFGetTypeID(result) == AXUIElementGetTypeID() else { throw AssistantSemanticSearch.Failure.metadata }
            return (result as! AXUIElement)
        }
        func string(_ item:AXUIElement,_ attribute:String) throws -> String? {
            guard let result=try value(item,attribute) else { return nil }
            guard let text=result as? String else { throw AssistantSemanticSearch.Failure.metadata }
            return text
        }
        func belongs(_ item:AXUIElement) throws -> Bool {
            try prepare(item)
            var pid:pid_t=0
            let result=AXUIElementGetPid(item,&pid)
            try budget.check()
            return result == .success && pid == target.pid
        }
        do {
            let app=AXUIElementCreateApplication(target.pid)
            try prepare(app)
            var hit:AXUIElement?
            let hitResult=AXUIElementCopyElementAtPosition(app,Float(point.x),Float(point.y),&hit)
            try budget.check()
            guard hitResult == .success, let hit else {
                Log.write(AssistantClickDiagnostics.line(reason:.hitTestFailed,phase:phase,depth:0,role:nil,axResult:hitResult.rawValue))
                throw AssistantActionError.unsupported
            }
            guard let window=try element(app,kAXFocusedWindowAttribute), try belongs(window) else {
                throw AssistantSemanticSearch.Failure.boundary
            }
            return try AssistantSemanticSearch.find(start:hit,budget:budget,equal:{ CFEqual($0,$1) }) { item,depth,_ in
                lastDepth=depth
                guard try belongs(item) else { return .blocked(.foreignProcess) }
                lastRole=try string(item,kAXRoleAttribute)
                if try string(item,kAXSubroleAttribute) == "AXSecureTextField" { return .blocked(.secure) }
                // Never climb into another AX window, the application, or a
                // sibling popup. WebArea parents remain eligible in this window.
                if CFEqual(item,window) { return .blocked(.noTarget) }
                guard let owner=try element(item,kAXWindowAttribute), CFEqual(owner,window) else { return .blocked(.boundary) }
                var labels:[String]=[]
                for attribute in [kAXTitleAttribute,kAXDescriptionAttribute,kAXHelpAttribute] {
                    if let label=try string(item,attribute) { labels.append(label) }
                }
                if Self.sensitiveWords(labels.joined(separator:" ")) && !approved {
                    throw AssistantActionError.confirmationRequired("This control may send, delete, publish or change access. Approve the click to continue.")
                }
                try prepare(item)
                let advertised:[String]
                if let actionNamesReader { advertised=actionNamesReader(item) }
                else {
                    var names:CFArray?
                    let result=AXUIElementCopyActionNames(item,&names)
                    guard result == .success, let values=names as? [String] else {
                        lastAXResult=result.rawValue; throw AssistantSemanticSearch.Failure.metadata
                    }
                    advertised=values
                }
                try budget.check()
                let role=lastRole ?? ""
                let enabledValue=try value(item,kAXEnabledAttribute)
                if let enabledValue, CFGetTypeID(enabledValue) != CFBooleanGetTypeID() { throw AssistantSemanticSearch.Failure.metadata }
                let enabled:Bool?=enabledValue.map { CFBooleanGetValue(($0 as! CFBoolean)) }
                guard enabled != false else { return .blocked(.disabled) }
                if AssistantClickPolicy.canPress(role:role,advertised:advertised,enabled:enabled) {
                    return .candidate(ClickTarget(element:item,kind:.press,role:role,depth:depth))
                }
                if ["AXTextField","AXTextArea","AXComboBox","AXSearchField"].contains(role) {
                    try prepare(item)
                    var writable=DarwinBoolean(false)
                    let status=AXUIElementIsAttributeSettable(item,kAXFocusedAttribute as CFString,&writable)
                    try budget.check()
                    if AssistantAXReadPolicy.disposition(status) == .failed {
                        lastAXResult=status.rawValue; throw AssistantSemanticSearch.Failure.metadata
                    }
                    if status == .success && writable.boolValue {
                        return .candidate(ClickTarget(element:item,kind:.focus,role:role,depth:depth))
                    }
                }
                guard let parent=try element(item,kAXParentAttribute) else { return .blocked(.noTarget) }
                return .parent(parent)
            }
        } catch let failure as AssistantSemanticSearch.Failure {
            let reason:AssistantClickDiagnostics.Reason
            switch failure {
            case .deadline: reason = .searchDeadline
            case .cycle: reason = .parentCycle
            case .depth: reason = .parentDepthExhausted
            case .boundary, .foreignProcess: reason = .windowBoundary
            case .secure: reason = .secureControl
            case .disabled: reason = .disabledControl
            case .noTarget: reason = .noSemanticTarget
            case .metadata: reason = .metadataReadFailed
            }
            Log.write(AssistantClickDiagnostics.line(reason:reason,phase:phase,
                depth:failure == .depth ? AssistantSemanticSearch.maximumNodes : lastDepth,role:lastRole,axResult:lastAXResult))
            if failure == .secure || failure == .foreignProcess { throw AssistantActionError.protected }
            throw AssistantActionError.unsupported
        }
    }
    private static func applicationForURL(_ url:URL,target:AssistantWindowReference) throws -> URL {
        guard let current = NSRunningApplication(processIdentifier:target.pid) else { throw AssistantActionError.changed }
        let bundle = current.bundleURL.flatMap(Bundle.init(url:))
        let types = bundle?.object(forInfoDictionaryKey:"CFBundleURLTypes") as? [[String:Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        if AssistantMapLinkPolicy.usesCurrentMaps(url:url,bundleID:current.bundleIdentifier) {
            guard let application = current.bundleURL, bundle?.bundleIdentifier == "com.apple.Maps" else { throw AssistantActionError.unsupported }
            return application
        }
        guard !AssistantMapLinkPolicy.refusesFallback(url:url,bundleID:current.bundleIdentifier) else { throw AssistantActionError.unsupported }
        switch AssistantBrowserPolicy.route(bundleID:current.bundleIdentifier,declaredSchemes:schemes) {
        case .current:
            guard let application = current.bundleURL, bundle?.bundleIdentifier == current.bundleIdentifier else { throw AssistantActionError.unsupported }
            return application
        case .refuse: throw AssistantActionError.unsupported
        case .systemDefault:
            guard let application = NSWorkspace.shared.urlForApplication(toOpen:url),
                  let id = Bundle(url:application)?.bundleIdentifier, !protectedApps.contains(id) else { throw AssistantActionError.unsupported }
            return application
        }
    }
    private func settleOpenedWindow(original:AssistantWindowReference,expectedPID:pid_t,epoch:UUID) async throws -> AssistantWindowReference {
        var readiness = AssistantWindowSettlePolicy(originalPID:original.pid,expectedPID:expectedPID,
            deadline:ProcessInfo.processInfo.systemUptime + 5)
        while true {
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let candidate = AssistantWindowReference.invocation()
            let window = candidate.flatMap { reference in reference.frame.map { AssistantWindowSettlePolicy.Window(id:reference.windowID,frame:$0) } }
            let decision = readiness.observe(now:ProcessInfo.processInfo.systemUptime,foregroundPID:foreground,window:window,
                activityUnchanged:epoch == generation && armed && !changed && !Task.isCancelled)
            switch decision {
            case .ready:
                guard let candidate, candidate.pid == expectedPID else { throw AssistantActionError.changed }
                try check(candidate)
                return candidate
            case .changed: throw AssistantActionError.changed
            case .timedOut: throw AssistantActionError.openedWindowUnavailable
            case .waiting: try await Task.sleep(for:.milliseconds(100))
            }
        }
    }
    private func editableField(_ target: AssistantWindowReference) throws -> AXUIElement {
        try check(target)
        let current = FocusedElement.current()
        let bundle = NSRunningApplication(processIdentifier:target.pid)?.bundleIdentifier ?? ""
        guard !["com.apple.Terminal","com.googlecode.iterm2","dev.warp.Warp-Stable"].contains(bundle) else { throw AssistantActionError.protected }
        guard current.pid == target.pid, let element = current.element, Self.belongs(element,to:target.pid),
              Self.string(element,kAXSubroleAttribute) != "AXSecureTextField",
              ["AXTextField","AXTextArea","AXComboBox","AXSearchField"].contains(Self.string(element,kAXRoleAttribute) ?? "") else { throw AssistantActionError.protected }
        let description = [kAXTitleAttribute,kAXDescriptionAttribute,kAXHelpAttribute].compactMap { Self.string(element,$0) }.joined(separator:" ").lowercased()
        guard !["terminal","console","password"].contains(where:description.contains), SelectionSnapshot.isWritable(element) else { throw AssistantActionError.protected }
        return element
    }
    private static func boolean(_ element:AXUIElement,_ attribute:String) -> Bool? {
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,attribute as CFString,&value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }
    private static func belongs(_ element:AXUIElement,to pid:pid_t) -> Bool {
        var actual:pid_t = 0
        return AXUIElementGetPid(element,&actual) == .success && actual == pid
    }
    private static func string(_ element:AXUIElement,_ attribute:String) -> String? {
        AXUIElementSetMessagingTimeout(element,0.1)
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,attribute as CFString,&value) == .success else { return nil }
        return value as? String
    }
    private static func element(_ source:AXUIElement,_ attribute:String) -> AXUIElement? {
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(source,attribute as CFString,&value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func sensitive(_ element:AXUIElement) -> Bool {
        let label = [kAXTitleAttribute,kAXDescriptionAttribute,kAXHelpAttribute].compactMap { string(element,$0) }.joined(separator:" ").lowercased()
        return sensitiveWords(label)
    }
    private static func sensitiveWords(_ label:String) -> Bool {
        let words = label.lowercased().split { !$0.isLetter }.map(String.init)
        let guarded:Set<String> = ["send","delete","remove","publish","submit","buy","pay","purchase","transfer","install","allow","grant","share","invite","erase","confirm"]
        return words.contains { guarded.contains($0) }
    }
}
