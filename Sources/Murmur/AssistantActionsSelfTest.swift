import AppKit
import ApplicationServices

/// Called only by the disposable external-editor test, never production startup.
@MainActor
enum AssistantActionsSelfTest {
    static func verify(pid:pid_t) async -> Bool {
        guard let reference = AssistantWindowReference.invocation(), reference.pid == pid,
              let focused = FocusedElement.current().element else { return false }
        // Exercise readiness with the disposable editor's actual foreground
        // window. This never opens a browser or changes an existing document.
        guard let frame = reference.frame else { return false }
        var settle = AssistantWindowSettlePolicy(originalPID:pid,expectedPID:pid,
            deadline:ProcessInfo.processInfo.systemUptime + 2)
        guard settle.observe(now:ProcessInfo.processInfo.systemUptime,foregroundPID:pid,
            window:.init(id:reference.windowID,frame:frame),activityUnchanged:true) == .waiting else { return false }
        try? await Task.sleep(for:.milliseconds(400))
        guard let current = AssistantWindowReference.invocation(), current.pid == pid, let currentFrame = current.frame,
              settle.observe(now:ProcessInfo.processInfo.systemUptime,foregroundPID:current.pid,
                window:.init(id:current.windowID,frame:currentFrame),activityUnchanged:true) == .ready else { return false }
        let executor = AssistantActions()
        defer { executor.cancel() }
        executor.begin(target:reference)
        var range = CFRange(location:0,length:10)
        guard let value = AXValueCreate(.cfRange,&range),
              AXUIElementSetAttributeValue(focused,kAXSelectedTextRangeAttribute as CFString,value) == .success else { return false }
        do {
            let receipt = try await executor.execute(.init(type:"type",text:"Sona action test"),target:reference)
            guard receipt.target.pid == pid,
                  SelectionSnapshot.string(focused,range:NSRange(location:0,length:16)) == "Sona action test" else { return false }
            guard try await verifyCursor(target:receipt.target,focused:focused) else { return false }
            do {
                _ = try await executor.execute(.init(type:"key",key:"enter"),target:receipt.target)
                return false
            } catch AssistantActionError.confirmationRequired { /* Enter was not posted. */ }
            guard SelectionSnapshot.string(focused,range:NSRange(location:0,length:16)) == "Sona action test" else { return false }
            do {
                _ = try await executor.execute(.init(type:"key",key:"cmd+q"),target:receipt.target)
                return false
            } catch AssistantActionError.unsupported { /* Undeclared shortcuts cannot run. */ }
            executor.cancel()
            do {
                _ = try await executor.execute(.init(type:"type",text:"must not insert"),target:receipt.target)
                return false
            } catch AssistantActionError.changed { /* Closing a chat invalidates all pending actions. */ }
            try await Task.sleep(for:.milliseconds(1000))
            return SelectionSnapshot.string(focused,range:NSRange(location:0,length:16)) == "Sona action test"
        } catch { return false }
    }

    private static func verifyCursor(target:AssistantWindowReference,focused:AXUIElement) async throws -> Bool {
        guard let frame = target.frame, let selection = SelectionSnapshot.read(focused),
              let realCursor = CGEvent(source:nil)?.location else { return false }
        // These points cover screens above, below and left of the primary. The
        // conversion must not use whichever screen happens to own a key window.
        guard AssistantCursor.appKitPoint(CGPoint(x:-800,y:-200),primaryDisplayTop:900) == CGPoint(x:-800,y:1100),
              AssistantCursor.appKitPoint(CGPoint(x:1600,y:1100),primaryDisplayTop:900) == CGPoint(x:1600,y:-200) else { return false }
        guard AssistantCursor.movementProgress(-1) == 0, AssistantCursor.movementProgress(2) == 1,
              AssistantCursor.movementProgress(0.5) == 0.5,
              AssistantCursor.movementDuration(from:.zero,to:CGPoint(x:20_000,y:20_000),reduceMotion:false) == 0.32,
              AssistantCursor.movementDuration(from:.zero,to:CGPoint(x:100,y:100),reduceMotion:true) == 0 else { return false }
        let marker = AssistantCursor()
        defer { marker.hide() }
        let keyWindow = NSApp.keyWindow
        let point = CGPoint(x:frame.midX,y:frame.midY)
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app,0.1)
        var before:AXUIElement?
        guard AXUIElementCopyElementAtPosition(app,Float(point.x),Float(point.y),&before) == .success, let before else { return false }
        try await marker.move(to:point)
        var underneath:AXUIElement?
        guard marker.isVisible, marker.isInputTransparent, !marker.isPulsing,
              AXUIElementCopyElementAtPosition(app,Float(point.x),Float(point.y),&underneath) == .success,
              let underneath, CFEqual(before,underneath), target.remainsForeground(),
              NSApp.keyWindow === keyWindow, FocusedElement.current().element.map({ CFEqual($0,focused) }) == true,
              SelectionSnapshot.read(focused) == selection, CGEvent(source:nil)?.location == realCursor else { return false }
        if ProcessInfo.processInfo.environment["SONA_CURSOR_PREVIEW"] == "1", let rect = marker.screenCaptureRect?.integral {
            let line = "cursor: rect \(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))\n"
            FileHandle.standardOutput.write(Data(line.utf8))
            try await Task.sleep(for:.milliseconds(450))
        }
        // Explicit visual fixture only. Production calls this after AX success.
        marker.applied()
        guard marker.isPulsing else { return false }
        try await Task.sleep(for:.milliseconds(280))
        guard !marker.isPulsing, target.remainsForeground(), SelectionSnapshot.read(focused) == selection else { return false }
        let movement = Task { @MainActor in try await marker.move(to:CGPoint(x:point.x+12,y:point.y+12)) }
        try await Task.sleep(for:.milliseconds(32))
        marker.hide()
        guard !marker.isVisible, !marker.isPulsing else { return false }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Instant placement can finish before cancellation under Reduce Motion.
            _ = try? await movement.value
        } else {
            do { try await movement.value; return false } catch is CancellationError { /* A cancelled marker cannot reappear. */ }
        }
        try await Task.sleep(for:.milliseconds(80))
        return !marker.isVisible && target.remainsForeground() && SelectionSnapshot.read(focused) == selection
            && CGEvent(source:nil)?.location == realCursor
    }
}
