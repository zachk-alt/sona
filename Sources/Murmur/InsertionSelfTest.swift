import AppKit
import ApplicationServices
import Foundation

/// Explicit installed-bundle smoke test. No AppState, audio, AI, or documents.
@MainActor
final class InsertionSelfTest: NSObject, NSApplicationDelegate {
    private struct Failure: Error { let message: String }
    private let previousApp: NSRunningApplication?
    private let originalClipboard: ClipboardSnapshot
    private let board = NSPasteboard.general
    private var ownedClipboardChanges: Set<Int> = []
    private var window: NSWindow?
    private var bar: StatusBarController?
    private let fieldA = NSTextView()
    private let fieldB = NSTextView()
    private var originalTarget: FocusedElement.Target?
    private var finished = false
    private var insertionTime: TimeInterval?
    private let firstText = "Sona native insertion test."
    private let pendingText = "Sona pending recovery test."
    private let compatibilityText = " Sona compatibility insertion test."

    private init(previousApp: NSRunningApplication?, clipboard: ClipboardSnapshot) {
        self.previousApp = previousApp
        self.originalClipboard = clipboard
    }

    /// Call from synchronous main before constructing AppState.
    static func run() -> Never {
        guard AXIsProcessTrusted() else {
            fputs("insertion-selftest: STOP: existing Sona Accessibility access is required; no permission was requested.\n", stderr)
            exit(2)
        }
        guard let clipboard = ClipboardSnapshot.capture(.general) else {
            fputs("insertion-selftest: STOP: original clipboard could not be preserved; nothing was changed.\n", stderr)
            exit(2)
        }
        let test = InsertionSelfTest(previousApp: NSWorkspace.shared.frontmostApplication, clipboard: clipboard)
        let app = NSApplication.shared
        app.delegate = test
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(test) { app.run() }
        exit(1)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Sona Insertion Self-Test"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        for (field, label, y) in [(fieldA, "Disposable field A", 152.0), (fieldB, "Disposable field B", 32.0)] {
            let caption = NSTextField(labelWithString: label)
            caption.frame = NSRect(x: 20, y: y + 80, width: 480, height: 20)
            content.addSubview(caption)
            field.frame = NSRect(x: 20, y: y, width: 480, height: 72)
            field.isRichText = false
            field.isEditable = true
            field.isSelectable = true
            field.font = .systemFont(ofSize: 17)
            field.textContainerInset = NSSize(width: 8, height: 8)
            field.backgroundColor = .textBackgroundColor
            content.addSubview(field)
        }
        window.contentView = content
        self.window = window
        // The normal Edit menu exercises actual Cmd-V routing to the responder.
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.makeFirstResponder(fieldA)
        later(0.5) { try self.captureAndShowPanel() }
        later(10) { throw Failure(message: "watchdog expired") }
    }

    private func captureAndShowPanel() throws {
        try require(ownsFocus(fieldA), "disposable field A did not obtain focus")
        originalTarget = FocusedElement.captureTarget()
        try require(originalTarget?.element != nil, "Accessibility did not expose a concrete test field")
        try require(originalTarget?.pid == ProcessInfo.processInfo.processIdentifier, "captured target was not this test process")
        let bar = StatusBarController()
        self.bar = bar
        bar.showRecording()
        bar.setSpectrum([Float](repeating: 0.35, count: AudioCapture.bandCount))
        later(0.2) { try self.insertIntoOriginalField() }
    }

    private func insertIntoOriginalField() throws {
        try require(ownsFocus(fieldA), "recording panel changed keyboard focus")
        let panels = NSApp.windows.filter { $0 is NSPanel && $0.level == .statusBar && $0.isVisible }
        try require(panels.count == 1 && !panels[0].canBecomeKey && !panels[0].canBecomeMain,
                    "recording panel was not visible and non-key/non-main")
        try require(FocusedElement.match(originalTarget, FocusedElement.captureTarget()) == .same,
                    "recording panel changed Accessibility target")
        insertionTime = ProcessInfo.processInfo.systemUptime
        let result = TextInserter.insert(firstText, into: originalTarget)
        if result == .paste { ownedClipboardChanges.insert(board.changeCount) }
        try require(result == .paste, "native insertion was retained instead of posted")
        later(1.25) { try self.verifyInsertionAndSwitchField() }
    }

    private func verifyInsertionAndSwitchField() throws {
        try require(ownsFocus(fieldA), "paste changed keyboard focus")
        try require(fieldA.string == firstText && fieldB.string.isEmpty, "native Cmd-V did not insert exactly once into field A")
        try require(clipboardMatchesOriginal(), "temporary paste did not restore the original clipboard")
        print("insertion-selftest: PASS: native paste delivered once; recording panel preserved focus; clipboard restored")
        FocusedElement.beginTrackingActivity { _ in false }
        // Reproduce an editor reporting AXError.noValue, while exercising the
        // actual foreground window capture and the real native paste pipeline.
        let unavailable = FocusedElement.Result(element: nil, error: .noValue, app: "Sona self-test",
                                                pid: ProcessInfo.processInfo.processIdentifier)
        let compatibilityTarget = FocusedElement.captureTarget(focus: unavailable)
        try require(compatibilityTarget?.element == nil && compatibilityTarget?.activity != nil,
                    "compatibility capture did not reproduce an unavailable AX field")
        let result = TextInserter.insert(compatibilityText, into: compatibilityTarget)
        if result == .paste { ownedClipboardChanges.insert(board.changeCount) }
        insertionTime = ProcessInfo.processInfo.systemUptime
        try require(result == .paste, "unavailable AX field was not accepted in the same untouched window")
        later(1.25) {
            try self.require(self.fieldA.string == self.firstText + self.compatibilityText,
                             "compatibility native paste did not arrive exactly once")
            try self.require(self.clipboardMatchesOriginal(), "compatibility paste did not restore clipboard")
            print("insertion-selftest: PASS: unavailable AX field pasted once into unchanged window; clipboard restored")
            FocusedElement.endTrackingActivity()
            self.window?.makeFirstResponder(self.fieldB)
            self.later(0.2) { try self.verifyChangedFieldAndRecovery() }
        }
    }

    private func verifyChangedFieldAndRecovery() throws {
        try require(ownsFocus(fieldB), "disposable field B did not obtain focus")
        let current = FocusedElement.captureTarget()
        try require(current?.element != nil && FocusedElement.match(originalTarget, current) == .fieldChanged,
                    "two disposable fields did not expose distinct Accessibility identities")
        let before = board.changeCount
        let result = TextInserter.insert(pendingText, into: originalTarget)
        try require(result == .pending && TextInserter.hasPendingText && TextInserter.pendingCount == 1,
                    "changed-field result was not retained")
        try require(board.changeCount == before && fieldB.string.isEmpty && fieldA.string == firstText + compatibilityText,
                    "changed-field refusal modified a field or clipboard")
        try require(TextInserter.copyPendingToClipboard(), "explicit pending recovery copy failed")
        let recoveryChange = board.changeCount
        ownedClipboardChanges.insert(recoveryChange)
        try require(board.string(forType: .string) == pendingText && !TextInserter.hasPendingText,
                    "pending recovery copy did not preserve the complete synthetic result")
        try require(originalClipboard.restore(board, onlyIfChangeCount: recoveryChange),
                    "test recovery copy could not restore its clipboard backup")
        try require(clipboardMatchesOriginal(), "recovery backup differs from the original clipboard")
        print("insertion-selftest: PASS: changed field refused; pending text copied completely; clipboard restored")
        bar?.showProcessing()
        later(0.15) {
            try self.require(self.ownsFocus(self.fieldB), "processing panel changed keyboard focus")
            self.finish(status: 0, message: "PASS: all native checks completed")
        }
    }

    private func ownsFocus(_ field: NSTextView) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            && window?.isKeyWindow == true && window?.firstResponder === field
    }

    private func clipboardMatchesOriginal() -> Bool {
        guard let actual = ClipboardSnapshot.capture(board), actual.items.count == originalClipboard.items.count else { return false }
        return zip(actual.items, originalClipboard.items).allSatisfy { current, original in
            let currentData = Dictionary(uniqueKeysWithValues: current.map { ($0.type.rawValue, $0.data) })
            let originalData = Dictionary(uniqueKeysWithValues: original.map { ($0.type.rawValue, $0.data) })
            return currentData == originalData
        }
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private func later(_ seconds: TimeInterval, _ work: @escaping @MainActor () throws -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            guard !finished else { return }
            do { try work() }
            catch let failure as Failure { finish(status: 1, message: "FAIL: \(failure.message)") }
            catch { finish(status: 1, message: "FAIL: unexpected test error") }
        }
    }

    private func finish(status: Int32, message: String) {
        guard !finished else { return }
        finished = true
        FocusedElement.endTrackingActivity()
        bar?.showIdle()
        // Let any real insertion lease complete before the process exits.
        let remainingLease = insertionTime.map { max(0, 1.2 - (ProcessInfo.processInfo.systemUptime - $0)) } ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.45, remainingLease)) { [self] in
            let currentChange = board.changeCount
            if ownedClipboardChanges.contains(currentChange) {
                originalClipboard.restore(board, onlyIfChangeCount: currentChange)
            }
            let shouldRestoreApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier
            window?.orderOut(nil)
            window?.close()
            // Respect a user who intentionally switched elsewhere during the test.
            if shouldRestoreApp, let previousApp, !previousApp.isTerminated,
               previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp.activate(options: [])
            }
            print("insertion-selftest: \(message)")
            fflush(stdout)
            exit(status)
        }
    }
}
