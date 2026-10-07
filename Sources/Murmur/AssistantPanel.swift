import AppKit

enum AssistantAction: String, CaseIterable {
    case editSelection = "edit_selection"
    case askScreen = "screen_ask"
    var requiresImage: Bool { self != .editSelection }
}
private final class AssistantButton: NSButton {
    override var needsPanelToBecomeKey: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Answer content hosted in the existing recording glass. No second window,
/// selectors, recording surface, or activation behavior lives here.
@MainActor
final class AssistantPanel: NSObject {
    var onStop: (() -> Void)?
    private let statusBar: StatusBarController
    private let content = NSView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let answer = NSTextView()
    private let scroll = NSScrollView()
    private let gestureHint = NSTextField(labelWithString: "")
    private let hotkeyName: String
    private let copy = AssistantButton(title: "Copy", target: nil, action: nil)
    private let stop = AssistantButton(title: "Stop", target: nil, action: nil)
    private var copyText = ""
    private var hasAnswer = false
    private var busy = false
    private var target: AssistantWindowReference?
    var isVisible: Bool { hasAnswer && statusBar.isAssistantVisible }

    init(statusBar: StatusBarController, hotkeyName: String = "right-option") {
        self.statusBar = statusBar
        self.hotkeyName = hotkeyName.replacingOccurrences(of: "-", with: " ")
        super.init()
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 2
        answer.isEditable = false; answer.isSelectable = false; answer.drawsBackground = false
        answer.font = .systemFont(ofSize: 14); answer.textColor = .labelColor
        answer.textContainerInset = .zero; answer.textContainer?.lineFragmentPadding = 0
        answer.isHorizontallyResizable = false; answer.isVerticallyResizable = true
        answer.textContainer?.widthTracksTextView = true
        scroll.documentView = answer; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        gestureHint.font = .systemFont(ofSize: 10)
        gestureHint.textColor = .secondaryLabelColor
        content.addSubview(status); content.addSubview(scroll); content.addSubview(gestureHint)
        for button in buttons {
            button.target = self; button.bezelStyle = .rounded; button.controlSize = .small
            button.font = .systemFont(ofSize: 11); content.addSubview(button)
        }
        copy.action = #selector(copyClicked)
        stop.action = #selector(stopClicked)
    }
    private var buttons: [AssistantButton] { [copy, stop] }

    /// Recording and initial processing stay entirely in the Command waveform.
    func setStatus(_ text: String, recording: Bool = false, busy: Bool = false) {
        self.busy = busy; status.stringValue = text
        if recording { hasAnswer = false; return }
        if hasAnswer { layoutAnswer(reveal: false) }
    }
    func setTranscript(_ text: String) { }
    func followWindow(_ target: AssistantWindowReference?) {
        self.target = target
        statusBar.followAssistantWindow(target)
    }
    func hide() { statusBar.suspendSurface() }
    func reveal() { statusBar.resumeSurface() }
    func restoreAnswer() { if hasAnswer { layoutAnswer(reveal: true) } }
    func finishResponse() {
        busy = false
        if hasAnswer { layoutAnswer(reveal: false) }
    }
    func showAnswer(_ text: String) {
        answer.string = text; copyText = text; hasAnswer = true
        layoutAnswer(reveal: true); answer.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func layoutAnswer(reveal: Bool) {
        statusBar.followAssistantWindow(target)
        let width: CGFloat = 340, inset: CGFloat = 16, textWidth = width - 2*inset
        answer.frame = NSRect(x: 0, y: 0, width: textWidth, height: 1)
        answer.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        if let container = answer.textContainer { answer.layoutManager?.ensureLayout(for: container) }
        let used = answer.textContainer.flatMap { answer.layoutManager?.usedRect(for: $0).height } ?? 40
        let statusHeight: CGFloat = status.stringValue.isEmpty ? 0 : min(30, ceil(status.cell?.cellSize(forBounds: NSRect(x: 0,y: 0,width: textWidth,height: 100)).height ?? 14))
        let textHeight = min(184-statusHeight, max(40, ceil(used)+2))
        let height = min(280, 16 + statusHeight + (statusHeight > 0 ? 8 : 0) + textHeight + 10 + 24 + 28)
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        status.frame = NSRect(x: inset, y: height-16-statusHeight, width: textWidth, height: statusHeight)
        scroll.frame = NSRect(x: inset, y: 62, width: textWidth, height: textHeight)
        answer.frame.size.height = max(textHeight, ceil(used)+2)
        copy.isHidden = copyText.isEmpty
        stop.isHidden = !busy
        gestureHint.stringValue = busy ? "Tap \(hotkeyName) to stop" : "Hold \(hotkeyName) to ask · Tap to close"
        gestureHint.frame = NSRect(x: inset, y: 12, width: textWidth, height: 13)
        var x = inset
        for button in buttons where !button.isHidden {
            button.sizeToFit()
            let buttonWidth = max(38, button.frame.width)
            button.frame = NSRect(x: x, y: 29, width: buttonWidth, height: 24); x += buttonWidth + 6
        }
        statusBar.showAssistantContent(content, size: content.frame.size, reveal: reveal)
    }
    @objc private func stopClicked() { onStop?() }
    @objc private func copyClicked() {
        guard !copyText.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copyText, forType: .string)
    }
}
