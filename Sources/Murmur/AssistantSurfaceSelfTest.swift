import AppKit
import ApplicationServices

/// Explicit presentation check. Shows only Sona's nonactivating surface.
/// No app activation, Space switch, screenshot, field text, microphone or AI.
@MainActor final class AssistantSurfaceSelfTest: NSObject, NSApplicationDelegate {
    private var bar: StatusBarController?
    private var frontmost: pid_t?
    private var focused: AXUIElement?
    private var cursor: CGPoint?

    static func run() -> Never {
        let app = NSApplication.shared, delegate = AssistantSurfaceSelfTest()
        app.setActivationPolicy(.prohibited); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(1)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmost != nil else { finish(false, "No active desktop is available."); return }
        if AXIsProcessTrusted() { focused = FocusedElement.current().element }
        cursor = CGEvent(source: nil)?.location
        Task { @MainActor in
            do { try await verify(); finish(true, "same glass, Space flags, hidden/fading behavior and nonactivation verified") }
            catch { finish(false, error.localizedDescription) }
        }
    }
    private func verify() async throws {
        let bar = StatusBarController(); self.bar = bar
        // NSStatusItem installs its window asynchronously. Sample the normal
        // anchor only after AppKit has placed the new menu item.
        try await Task.sleep(for: .milliseconds(200))
        bar.showRecording()
        try await Task.sleep(for: .milliseconds(100))
        bar.showRecording()
        guard let panel = NSApp.windows.first(where: { $0.windowNumber == bar.panelWindowNumber }) else {
            throw Failure("Owned surface missing.")
        }
        let identity = panel.windowNumber, compact = bar.panelGlassSize, originalFrame = panel.frame
        let ordinarySpaces = panel.collectionBehavior
        try require(ordinarySpaces == [.canJoinAllSpaces, .stationary, .ignoresCycle], "Ordinary dictation behavior changed.")
        try unchanged(panel)
        try visibleGlass(panel)
        try bar.exerciseHiddenStatusItem {
            bar.showRecording()
            try require(panel.isVisible, "Missing menu item hid the recording surface.")
            try visibleGlass(panel)
            try unchanged(panel)
        }
        // Give AppKit the same time to place the restored item as at startup.
        try await Task.sleep(for: .milliseconds(200))
        bar.showRecording()
        try visibleGlass(panel)
        try unchanged(panel)
        guard let screen = NSScreen.screens.first,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw Failure("No display geometry is available.")
        }
        // This presentation-only fixture does not need access to another
        // app's window list. It never captures or acts on this synthetic ID.
        let target = AssistantWindowReference(pid: getpid(), windowID: 0, frame: CGDisplayBounds(displayID.uint32Value))
        let answer = AssistantPanel(statusBar: bar)
        answer.followWindow(target)
        bar.showProcessing()
        answer.showAnswer("Disposable Sona panel check.")
        try require(panel.collectionBehavior.contains([.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]), "Option surface cannot join other app groups.")
        try require(panel.windowNumber == identity && panel.isVisible, "Option replaced or hid the shared surface.")
        let expanded = bar.panelGlassSize
        try require(expanded.width == 340 && expanded.height <= 280, "Response size changed unexpectedly.")
        try unchanged(panel)

        bar.suspendSurface()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        answer.followWindow(target)
        try await Task.sleep(for: .milliseconds(30))
        try require(!panel.isVisible, "A display notification revealed a suspended surface.")
        answer.restoreAnswer()
        try require(panel.isVisible && panel.windowNumber == identity && bar.panelGlassSize == expanded, "Restoring the answer replaced or resized its surface.")
        try unchanged(panel)

        let fadingFrame = panel.frame
        bar.showIdle()
        answer.followWindow(target)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try require(panel.frame == fadingFrame, "Reanchoring moved the surface after dismissal began.")
        try await Task.sleep(for: .milliseconds(450))
        try require(!panel.isVisible && panel.collectionBehavior == ordinarySpaces, "Dismissal retained Assistant placement behavior.")
        bar.showRecording()
        try require(panel.windowNumber == identity, "Ordinary dictation changed its surface ID: \(identity) -> \(panel.windowNumber).")
        try require(bar.panelGlassSize == compact, "Ordinary dictation changed its glass size: \(compact) -> \(bar.panelGlassSize).")
        try require(panel.frame == originalFrame, "Ordinary dictation changed its menu anchor: \(originalFrame) -> \(panel.frame).")
        try unchanged(panel)
        bar.suspendSurface()
    }
    private func visibleGlass(_ panel: NSWindow) throws {
        let glass = panel.frame.insetBy(dx: 26, dy: 26)
        try require(NSScreen.screens.contains { $0.visibleFrame.contains(glass) },
                    "Recording glass was ordered onscreen but is outside every visible display.")
    }
    private func unchanged(_ panel: NSWindow) throws {
        try require(!panel.canBecomeKey && !panel.canBecomeMain && !panel.isKeyWindow && !panel.isMainWindow
                    && panel.styleMask.contains(.nonactivatingPanel) && panel.level == .statusBar,
                    "Surface became activating or changed level.")
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost
                    && CGEvent(source: nil)?.location == cursor, "Foreground app or real cursor changed.")
        if let focused {
            try require(FocusedElement.current().element.map { CFEqual($0, focused) } == true, "Focused field identity changed.")
        }
    }
    private func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message) } }
    private func finish(_ success: Bool, _ message: String) {
        bar?.suspendSurface()
        print("assistant-surface-selftest: \(success ? "PASS" : "FAIL"): \(message); fieldIdentityChecked=\(focused != nil)")
        fflush(stdout); exit(success ? 0 : 1)
    }
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
