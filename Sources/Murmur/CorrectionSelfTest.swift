import AppKit
import ApplicationServices

/// Two disposable processes exercise production process-scoped input and AX notifications.
/// No provider, microphone, settings, or preexisting document is involved.
@MainActor
final class CorrectionSelfTest: NSObject, NSApplicationDelegate {
    private let host: Bool
    private var window: NSWindow?
    private var child: Process?
    private var previous: NSRunningApplication?
    private var clipboard: ClipboardSnapshot?
    private var clipboardLease: Int?
    private let correction = CorrectionObservation()
    private var target: FocusedElement.Target?
    private var correctionAccepted = false
    private var done = false
    init(host: Bool) { self.host = host }
    static func run(host: Bool) -> Never {
        if host && !AXIsProcessTrusted() { print("correction-selftest: STOP: existing Accessibility grant required"); exit(2) }
        let delegate = CorrectionSelfTest(host: host), app = NSApplication.shared
        app.setActivationPolicy(host ? .prohibited : .accessory); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }; exit(1)
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        if !host { showOwnedEditor(); return }
        previous = NSWorkspace.shared.frontmostApplication
        guard let saved = ClipboardSnapshot.capture(.general) else { finish(false,"clipboard cannot be preserved"); return }
        clipboard = saved
        let process = Process(); child = process
        process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath:CommandLine.arguments[0])
        process.arguments = ["--owned-correction-editor"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { finish(false,"owned editor did not launch"); return }
        later(0.7) { self.begin() }
        later(20) { self.finish(false,"watchdog expired") }
    }
    private func showOwnedEditor() {
        let frame = NSRect(x:0,y:0,width:540,height:190)
        let window = NSWindow(contentRect:frame,styleMask:[.titled],backing:.buffered,defer:false)
        self.window = window; window.title = "Sona disposable correction editor"; window.isReleasedWhenClosed = false
        let field = NSTextView(frame:NSRect(x:20,y:20,width:500,height:140))
        field.isRichText = false; field.isEditable = true; field.font = .systemFont(ofSize:20)
        let menu = NSMenu(), item = NSMenuItem(title:"Edit",action:nil,keyEquivalent:"")
        let edit = NSMenu(title:"Edit"); edit.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        item.submenu = edit; menu.addItem(item); NSApp.mainMenu = menu
        window.contentView?.addSubview(field)
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true); window.makeFirstResponder(field)
        DispatchQueue.main.asyncAfter(deadline:.now()+30) { exit(0) }
    }
    private func begin() {
        guard let child, NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier else { finish(false,"owned editor did not retain focus"); return }
        FocusedElement.beginTrackingActivity { TextInserter.isOwnPasteEvent($0) }
        guard let baseline = SelectionSnapshot.emptyFieldBaseline(), baseline.target.pid == child.processIdentifier else { finish(false,"empty editable AX baseline unavailable"); return }
        target = baseline.target
        let method = TextInserter.insert("Hello Jon.",into:baseline.target)
        if method == .paste { clipboardLease = NSPasteboard.general.changeCount }
        guard method == .paste else { finish(false,"owned paste refused"); return }
        later(0.35) {
            self.correction.enabled = true
            self.correction.onSuggestion = { [weak self] word in
                guard let self else { return }
                if word == "Jan" { self.verifyStop() }
            }
            self.correction.verifyAndBegin(text:"Hello Jon.",before:baseline)
            guard self.correction.isObserving else { self.finish(false,"production observer did not start after real paste"); return }
            guard let element = baseline.target.element else { self.finish(false,"lost owned field"); return }
            var range = CFRange(location:6,length:3)
            guard let value = AXValueCreate(.cfRange,&range),
                  AXUIElementSetAttributeValue(element,kAXSelectedTextRangeAttribute as CFString,value) == .success else { self.finish(false,"owned selection refused"); return }
            self.later(0.2) { self.character("J",code:38) }
            self.later(0.45) { self.character("a",code:0) }
            self.later(0.7) { self.character("n",code:45) }
            self.later(2.0) {
                guard !self.correctionAccepted else { return }
                if self.correction.isObserving { self.finish(false,"native edit did not offer corrected word") }
                else if !self.done { self.finish(false,"observation stopped before correction") }
            }
        }
    }
    private func character(_ text:String,code:CGKeyCode) {
        guard let target, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { finish(false,"focus moved before owned test key"); return }
        guard let source = CGEventSource(stateID:.combinedSessionState),
              let down = CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:true),
              let up = CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:false) else { finish(false,"test event unavailable"); return }
        down.flags = []; up.flags = []
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { pointer in
            down.keyboardSetUnicodeString(stringLength:pointer.count,unicodeString:pointer.baseAddress)
            up.keyboardSetUnicodeString(stringLength:pointer.count,unicodeString:pointer.baseAddress)
        }
        down.postToPid(target.pid); up.postToPid(target.pid)
    }
    private func verifyStop() {
        guard !correctionAccepted else { return }
        guard let target, let element = target.element,
              SelectionSnapshot.string(element,range:NSRange(location:0,length:10)) == "Hello Jan." else { finish(false,"candidate did not match owned field"); return }
        correctionAccepted = true
        correction.enabled = false
        let reads = correction.contentReads
        later(0.2) {
            guard !self.correction.isObserving && self.correction.contentReads == reads else { self.finish(false,"disabled correction teardown failed"); return }
            self.finish(true,"owned correction suggestion and disabled observer teardown verified")
        }
    }
    private func later(_ delay:Double,_ body:@escaping()->Void) {
        DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [weak self] in guard let self, !self.done else { return }; body() }
    }
    private func finish(_ success:Bool,_ message:String) {
        guard !done else { return }; done = true; let reason = correction.lastStopReason; correction.stop(reason:reason); FocusedElement.endTrackingActivity()
        let wasOwned = child.map { NSWorkspace.shared.frontmostApplication?.processIdentifier == $0.processIdentifier } ?? false
        if let clipboardLease { clipboard?.restore(.general,onlyIfChangeCount:clipboardLease) }
        child?.terminate()
        if wasOwned { previous?.activate(options:[]) }
        print("correction-selftest diagnostics: witnesses=\(correction.inputWitnesses), values=\(correction.valueNotifications), reads=\(correction.contentReads), stop=\(correction.lastStopReason)")
        print("correction-selftest: \(success ? "PASS" : "FAIL"): \(message)"); fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { exit(success ? 0 : 1) }
    }
}
