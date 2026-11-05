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
        // NSStatusItem installs its window asynchronously, and macOS can
        // shift it again about half a second later. Anchor only after it
        // stops moving, since a panel on screen keeps its first place.
        try await settle(bar)
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
        // The menu icon moves while recording (macOS adds its microphone
        // indicator to the menu bar). Processing must stay exactly where
        // recording appeared, not chase the icon.
        let recordingFrame = panel.frame
        try bar.exerciseHiddenStatusItem {
            bar.showProcessing()
            try require(panel.frame == recordingFrame,
                        "Processing moved the panel: \(recordingFrame) -> \(panel.frame).")
        }
        bar.showProcessing()
        try require(panel.frame == recordingFrame,
                    "Processing moved the panel after the icon returned: \(recordingFrame) -> \(panel.frame).")
        try await Task.sleep(for: .milliseconds(100))
        try require(panel.windowNumber == identity && panel.isVisible && bar.panelGlassSize == compact,
                    "Processing replaced, hid or resized the recording surface.")
        try require(bar.isActivityHighlighted, "Processing lost the blue activity icon.")
        try visibleGlass(panel)
        try unchanged(panel)
        bar.showIdle()
        try await Task.sleep(for: .milliseconds(450))
        try require(!panel.isVisible && panel.collectionBehavior == ordinarySpaces, "Dismissal failed.")
        try await settle(bar)
        bar.showRecording()
        try require(panel.windowNumber == identity, "Ordinary dictation changed its surface ID: \(identity) -> \(panel.windowNumber).")
        try require(bar.panelGlassSize == compact, "Ordinary dictation changed its glass size: \(compact) -> \(bar.panelGlassSize).")
        try require(panel.frame == originalFrame, "Ordinary dictation changed its menu anchor: \(originalFrame) -> \(panel.frame).")
        try unchanged(panel)
        bar.suspendSurface()
    }
    /// Wait until the menu item has held one place for 700 ms, at most 4 s.
    private func settle(_ bar: StatusBarController) async throws {
        var last = bar.menuAnchorRect, steady = 0
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(50))
            let now = bar.menuAnchorRect
            steady = now == last ? steady + 1 : 0
            last = now
            if steady >= 14 { return }
        }
        throw Failure("Menu item never settled.")
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
