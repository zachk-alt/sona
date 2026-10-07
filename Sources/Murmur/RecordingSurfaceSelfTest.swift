import AppKit
import ApplicationServices

/// Explicit presentation check. Shows only Sona's nonactivating surface.
/// No app activation, Space switch, screenshot, field text, microphone or AI.
@MainActor final class RecordingSurfaceSelfTest: NSObject, NSApplicationDelegate {
    private var bar: StatusBarController?
    private var frontmost: pid_t?
    private var focused: AXUIElement?
    private var cursor: CGPoint?

    static func run() -> Never {
        let app = NSApplication.shared, delegate = RecordingSurfaceSelfTest()
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
        try require(ordinarySpaces == [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle], "Recording cannot join other apps in full screen or Stage Manager.")
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
        bar.showProcessing()
        try await Task.sleep(for: .milliseconds(100))
        try require(panel.windowNumber == identity && panel.isVisible && bar.panelGlassSize == compact,
                    "Processing replaced, hid or resized the recording surface.")
        try require(bar.isActivityHighlighted, "Processing lost the blue activity icon.")
        try visibleGlass(panel)
        try unchanged(panel)
        bar.showIdle()
        try await Task.sleep(for: .milliseconds(450))
        try require(!panel.isVisible && panel.collectionBehavior == ordinarySpaces, "Dismissal failed.")
        bar.showRecording()
        try require(panel.windowNumber == identity, "Ordinary dictation changed its surface ID: \(identity) -> \(panel.windowNumber).")
        try require(bar.panelGlassSize == compact, "Ordinary dictation changed its glass size: \(compact) -> \(bar.panelGlassSize).")
        try require(panel.frame == originalFrame, "Ordinary dictation changed its menu anchor: \(originalFrame) -> \(panel.frame).")
        try unchanged(panel)
        bar.suspendSurface()
    }
    private func visibleGlass(_ panel: NSWindow) throws {
        try require(panel.isVisible && panel.isOnActiveSpace,
                    "Recording surface did not join the active Space.")
        try require(panel.occlusionState.contains(.visible),
                    "Recording surface is hidden behind another app.")
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
        print("recording-surface-selftest: \(success ? "PASS" : "FAIL"): \(message); fieldIdentityChecked=\(focused != nil)")
        fflush(stdout); exit(success ? 0 : 1)
    }
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
