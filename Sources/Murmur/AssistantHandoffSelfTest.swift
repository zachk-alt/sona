import AppKit
import ApplicationServices
import ImageIO

/// Explicit native test, using two separately bundled disposable apps only.
/// No microphone, model, existing document or screenshot file is involved.
@MainActor final class AssistantHandoffSelfTest:NSObject,NSApplicationDelegate {
    private let fixtures:URL
    private let lateResize:Bool
    private var owned:[NSRunningApplication]=[]
    private var previous:NSRunningApplication?
    private var task:Task<Void,Never>?
    private let executor=AssistantActions()
    private var finished=false
    private var phase="setup"
    private let began=ProcessInfo.processInfo.systemUptime
    private init(fixtures:URL,lateResize:Bool) { self.fixtures=fixtures; self.lateResize=lateResize }

    static func run(fixtures:URL,lateResize:Bool) -> Never {
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            print("assistant-handoff-selftest: STOP: existing Accessibility and Screen Recording grants are required. No permission was requested.")
            exit(2)
        }
        let app=NSApplication.shared, delegate=AssistantHandoffSelfTest(fixtures:fixtures,lateResize:lateResize)
        app.setActivationPolicy(.prohibited); app.delegate=delegate
        withExtendedLifetime(delegate) { app.run() }; exit(1)
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        previous=NSWorkspace.shared.frontmostApplication
        task=Task { @MainActor in
            do { try await verify(); finish(true,"open, target receipt, two memory captures and one native AX press verified") }
            catch { finish(false,"phase=\(phase) reason=\(error.localizedDescription)") }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+35) { self.finish(false,"owned test watchdog expired") }
    }
    private func verify() async throws {
        let originURL=try fixture("origin"), targetURL=try fixture("target")
        guard NSRunningApplication.runningApplications(withBundleIdentifier:"dev.sona.qa.origin").isEmpty,
              NSRunningApplication.runningApplications(withBundleIdentifier:"dev.sona.qa.target").isEmpty else {
            throw TestFailure("A fixture is already running; no existing app was reused.")
        }
        phase="prelaunch-target"
        let targetApp=try await launch(targetURL,activates:false,arguments:lateResize ? ["--late-resize"] : [])
        owned.append(targetApp)
        phase="launch-origin"
        let originApp=try await launch(originURL,activates:true,arguments:[])
        owned.append(originApp)
        phase="origin-readiness"
        let origin=try await waitForWindow(pid:originApp.processIdentifier)
        report("origin-ready",target:origin)
        executor.begin(target:origin)
        phase="production-open-target"
        let receipt=try await executor.execute(.init(type:"open_app",appId:"dev.sona.qa.target"),target:origin)
        guard receipt.target.pid == targetApp.processIdentifier, executor.permitsRequest(receipt.target) else {
            throw TestFailure("Native open receipt did not retain the owned target.")
        }
        let target=receipt.target
        report("target-receipt",target:target)
        phase="capture-after-open"
        let first=try await AssistantScreenCapture().captureExplicitAction(target)
        try verifyImage(first,green:false)
        report("first-capture",target:target,image:first)
        guard let focused=FocusedElement.current().element, FocusedElement.current().pid == target.pid,
              let realCursor=CGEvent(source:nil)?.location else { throw TestFailure("Owned target focus unavailable.") }
        let app=AXUIElementCreateApplication(target.pid); AXUIElementSetMessagingTimeout(app,0.2)
        guard let window=element(app,kAXFocusedWindowAttribute),
              let button=find("sona-handoff-button",in:window), let status=find("sona-handoff-status",in:window),
              string(status,kAXValueAttribute) == "target:0", let action=click(button,target:target) else {
            throw TestFailure("Known target fixture controls or initial marker missing.")
        }
        phase="native-click"
        let after=try await executor.execute(action,target:target)
        guard after.target.pid == target.pid, string(status,kAXValueAttribute) == "target:1",
              FocusedElement.current().element.map({ CFEqual($0,focused) }) == true,
              CGEvent(source:nil)?.location == realCursor else { throw TestFailure("Owned click, focus or real cursor verification failed.") }
        phase="capture-after-click"
        let second=try await AssistantScreenCapture().captureExplicitAction(after.target)
        try verifyImage(second,green:true)
        guard string(status,kAXValueAttribute) == "target:1", executor.permitsRequest(after.target) else {
            throw TestFailure("Action repeated or target changed after capture.")
        }
        report("second-capture",target:after.target,image:second)
    }
    private func fixture(_ role:String) throws -> URL {
        let url=fixtures.appendingPathComponent("SonaHandoff-\(role).app").standardizedFileURL
        guard Bundle(url:url)?.bundleIdentifier == "dev.sona.qa.\(role)",
              let executable=Bundle(url:url)?.executableURL, FileManager.default.isExecutableFile(atPath:executable.path) else {
            throw TestFailure("Prepare the distinct signed fixture bundles before this test.")
        }
        return url
    }
    private func launch(_ url:URL,activates:Bool,arguments:[String]) async throws -> NSRunningApplication {
        let config=NSWorkspace.OpenConfiguration()
        config.activates=activates; config.promptsUserIfNeeded=false; config.addsToRecentItems=false
        config.allowsRunningApplicationSubstitution=false; config.arguments=arguments
        return try await AssistantCaptureDeadline<NSRunningApplication>().wait(seconds:5) { completion in
            NSWorkspace.shared.openApplication(at:url,configuration:config) { app,error in
                if let app { completion(.success(app)) }
                else { completion(.failure(error ?? TestFailure("Fixture launch failed."))) }
            }
        }
    }
    private func waitForWindow(pid:pid_t) async throws -> AssistantWindowReference {
        let deadline=ProcessInfo.processInfo.systemUptime+5
        var previous:AssistantWindowReference?, stableSince=ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let candidate=AssistantWindowReference.invocation(), candidate.pid == pid {
                if candidate.windowID != previous?.windowID || candidate.frame != previous?.frame {
                    previous=candidate; stableSince=ProcessInfo.processInfo.systemUptime
                } else if ProcessInfo.processInfo.systemUptime-stableSince >= 0.35 { return candidate }
            } else { previous=nil }
            try await Task.sleep(for:.milliseconds(50))
        }
        throw TestFailure("Distinct origin fixture did not acquire a stable foreground window.")
    }
    private func verifyImage(_ image:AssistantScreenImage,green:Bool) throws {
        guard let data=Data(base64Encoded:image.dataBase64), data.count <= AssistantCapturePolicy.maximumBytes,
              let source=CGImageSourceCreateWithData(data as CFData,nil), let decoded=CGImageSourceCreateImageAtIndex(source,0,nil),
              decoded.width == image.width, decoded.height == image.height,
              max(image.width,image.height) <= AssistantCapturePolicy.maximumEdge,
              image.width*image.height <= AssistantCapturePolicy.maximumPixels,
              let sample=decoded.cropping(to:CGRect(x:Double(image.width)*0.8,y:Double(image.height)*0.5,width:1,height:1)) else {
            throw TestFailure("In-memory JPEG validation failed.")
        }
        var pixel=[UInt8](repeating:0,count:4)
        let rendered=pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context=CGContext(data:bytes.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(sample,in:CGRect(x:0,y:0,width:1,height:1)); return true
        }
        let r=Int(pixel[0]), g=Int(pixel[1]), b=Int(pixel[2])
        guard rendered, green ? (g > r+60 && g > b+50) : (b > r+80 && b > g+60) else {
            throw TestFailure("Captured pixels did not match the owned target's expected color marker.")
        }
    }
    private func report(_ stage:String,target:AssistantWindowReference,image:AssistantScreenImage?=nil) {
        let frame=target.frame ?? .zero
        print("assistant-handoff-selftest: stage=\(stage) elapsed=\(String(format:"%.3f",ProcessInfo.processInfo.systemUptime-began)) pid=\(target.pid) window=\(target.windowID) rect=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)) pixels=\(image?.width ?? 0)x\(image?.height ?? 0) lateResize=\(lateResize)")
        fflush(stdout)
    }
    private func finish(_ success:Bool,_ detail:String) {
        guard !finished else { return }; finished=true
        task?.cancel(); executor.cancel()
        let current=NSWorkspace.shared.frontmostApplication
        let restore=owned.contains { $0.processIdentifier == current?.processIdentifier }
        for app in owned where !app.isTerminated { app.terminate() }
        if restore, let previous, !previous.isTerminated { previous.activate(options:[]) }
        print("assistant-handoff-selftest: \(success ? "PASS" : "FAIL"): \(detail)"); fflush(stdout)
        exit(success ? 0 : 1)
    }
    private func string(_ source:AXUIElement,_ attribute:String) -> String? {
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(source,attribute as CFString,&value) == .success else { return nil }
        return value as? String
    }
    private func element(_ source:AXUIElement,_ attribute:String) -> AXUIElement? {
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(source,attribute as CFString,&value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func find(_ identifier:String,in root:AXUIElement) -> AXUIElement? {
        var queue=[root], visited=0
        while !queue.isEmpty && visited < 256 {
            let item=queue.removeFirst(); visited += 1; AXUIElementSetMessagingTimeout(item,0.1)
            if string(item,kAXIdentifierAttribute) == identifier { return item }
            var children:CFTypeRef?
            if AXUIElementCopyAttributeValue(item,kAXChildrenAttribute as CFString,&children) == .success,
               let children=children as? [AXUIElement] { queue.append(contentsOf:children.prefix(64)) }
        }
        return nil
    }
    private func click(_ element:AXUIElement,target:AssistantWindowReference) -> BridgeAction? {
        var position:CFTypeRef?, size:CFTypeRef?, point=CGPoint.zero, extent=CGSize.zero
        guard let frame=target.frame,
              AXUIElementCopyAttributeValue(element,kAXPositionAttribute as CFString,&position) == .success,
              AXUIElementCopyAttributeValue(element,kAXSizeAttribute as CFString,&size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue,.cgPoint,&point), AXValueGetValue(size as! AXValue,.cgSize,&extent) else { return nil }
        return .init(type:"click",x:(point.x+extent.width/2-frame.minX)/frame.width,y:(point.y+extent.height/2-frame.minY)/frame.height)
    }
    private struct TestFailure:LocalizedError {
        let message:String
        init(_ message:String) { self.message=message }
        var errorDescription:String? { message }
    }
}
