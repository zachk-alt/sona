import AppKit

/// A normal settings window, shown only by explicit setup/menu action.
@MainActor
final class HotKeySettings: NSWindowController, NSWindowDelegate {
    private let field = NSTextField(string: "right-command")
    private let message = NSTextField(wrappingLabelWithString: "Tap to start, tap again to finish. Or hold to talk.")
    private var monitor: Any?
    private var recording = false
    private var pendingModifier: String?
    private let completion: (String?) -> Void
    private var finished = false

    init(current: String, completion: @escaping (String?) -> Void) {
        self.completion = completion
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:440,height:248), styleMask:[.titled,.closable], backing:.buffered, defer:false)
        window.title = "Sona hotkey"
        window.isReleasedWhenClosed = false
        super.init(window:window)
        window.delegate = self
        field.stringValue = current
        field.placeholderString = "right-command or option+space"
        let title = NSTextField(labelWithString: "Choose your dictation hotkey")
        title.font = .systemFont(ofSize:19,weight:.semibold)
        let record = NSButton(title:"Record shortcut", target:self, action:#selector(recordShortcut))
        let save = NSButton(title:"Save", target:self, action:#selector(saveShortcut))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title:"Cancel", target:self, action:#selector(cancelShortcut))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views:[cancel,save]); buttons.orientation = .horizontal; buttons.spacing = 12
        let stack = NSStackView(views:[title,message,field,record,buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:24),field.widthAnchor.constraint(equalTo:stack.widthAnchor)])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func present() { window?.center(); NSApp.activate(ignoringOtherApps:true); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    @objc private func recordShortcut() {
        stopRecording(); recording = true
        message.stringValue = "Press your shortcut, then release it. Escape cancels recording."
        monitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.flagsChanged]) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.stopRecording(); return nil }
            if event.type == .flagsChanged {
                if let pending = self.pendingModifier, let binding = HotKeyBinding(pending), UInt64(event.modifierFlags.rawValue) & binding.deviceFlag! == 0 {
                    self.field.stringValue = pending; self.stopRecording()
                } else if let name = HotKeyBinding.name(for:event) { self.pendingModifier = name }
                return nil
            }
            if let name = HotKeyBinding.name(for:event), HotKeyBinding(name) != nil {
                self.field.stringValue = name; self.stopRecording()
            }
            return nil
        }
    }
    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = false; pendingModifier = nil
        message.stringValue = "Tap to start, tap again to finish. Or hold to talk."
    }
    @objc private func saveShortcut() {
        guard let binding = HotKeyBinding(field.stringValue) else {
            message.stringValue = "Use a key such as right-command, f8, or control+option+space."
            return
        }
        finish(binding.name)
    }
    @objc private func cancelShortcut() { finish(nil) }
    private func finish(_ name:String?) {
        guard !finished else { return }; finished = true
        stopRecording(); close(); completion(name)
    }
    func windowWillClose(_ notification:Notification) { finish(nil) }
}
