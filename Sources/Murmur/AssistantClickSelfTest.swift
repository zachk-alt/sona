import AppKit
import ApplicationServices

/// Disposable semantic controls. The test supplies an empty advisory action list
/// to reproduce Maps metadata while retaining real native AXPress dispatch.
/// These views never appear in a production application window.
@MainActor
private final class SemanticPressControl: NSView {
    private let fixtureID: String
    private let fixtureRole: NSAccessibility.Role
    private let enabled: Bool
    private var attempts = 0
    init(frame: NSRect, identifier: String, role: NSAccessibility.Role, enabled: Bool) {
        fixtureID = identifier; fixtureRole = role; self.enabled = enabled
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityIdentifier(identifier)
        setAccessibilityRole(role)
        setAccessibilityEnabled(enabled)
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { fixtureRole }
    override func accessibilityLabel() -> String? { "Fixture \(fixtureID) \(attempts)" }
    override func accessibilityValue() -> Any? { NSNumber(value: attempts) }
    override func isAccessibilityEnabled() -> Bool { enabled }
    override func accessibilityPerformPress() -> Bool {
        attempts += 1
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
        return enabled
    }
    override func draw(_ dirtyRect: NSRect) {
        (enabled ? NSColor.controlAccentColor : NSColor.disabledControlTextColor).withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        let text = "\(fixtureID): \(attempts)"
        (text as NSString).draw(at: NSPoint(x: 7, y: 4), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: enabled ? NSColor.labelColor : NSColor.disabledControlTextColor
        ])
    }
}

@MainActor
enum AssistantClickSelfTest {
    static func install(in content: NSView) {
        for (index, item) in [("press-button", NSAccessibility.Role.button, true),
                              ("press-radio", NSAccessibility.Role.radioButton, true),
                              ("press-disabled", NSAccessibility.Role.button, false)].enumerated() {
            content.addSubview(SemanticPressControl(frame: NSRect(x: 20 + index * 173, y: 162, width: 154, height: 24),
                identifier: item.0, role: item.1, enabled: item.2))
        }
    }
    /// Read only these named controls in the disposable child, before any editor mutation.
    static func diagnose(pid: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.2)
        var ownedWindow = element(app, kAXFocusedWindowAttribute)
        if ownedWindow == nil {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success {
                ownedWindow = (raw as? [AXUIElement])?.first
            }
        }
        guard let ownedWindow else { print("assistant-click-selftest initial metadata: owned window unavailable"); fflush(stdout); return }
        for identifier in ["press-button", "press-radio", "press-disabled"] {
            guard let control = find(identifier, under: ownedWindow) else {
                print("assistant-click-selftest initial metadata: \(identifier) missing"); continue
            }
            var names: CFArray?, rawValue: CFTypeRef?
            let status = AXUIElementCopyActionNames(control, &names)
            let valueStatus = AXUIElementCopyAttributeValue(control, kAXValueAttribute as CFString, &rawValue)
            print("assistant-click-selftest initial metadata: id=\(identifier) role=\(string(control, kAXRoleAttribute) ?? "nil") enabled=\(boolean(control, kAXEnabledAttribute).map(String.init) ?? "nil") count=\(count(control).map(String.init) ?? "nil") valueStatus=\(valueStatus.rawValue) numericValue=\((rawValue as? NSNumber)?.stringValue ?? "nil") description=\(string(control, kAXDescriptionAttribute) ?? "nil") actionStatus=\(status.rawValue) actions=\((names as? [String])?.joined(separator: ",") ?? "nil")")
        }
        fflush(stdout)
    }
    static func verify(pid: pid_t) async -> Bool {
        guard let reference = AssistantWindowReference.invocation(), reference.pid == pid,
              let focused = FocusedElement.current().element, let selection = SelectionSnapshot.read(focused),
              let originalCursor = CGEvent(source: nil)?.location else { return failed("owned foreground baseline unavailable") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let window = element(app, kAXFocusedWindowAttribute),
              let button = find("press-button", under: window),
              let radio = find("press-radio", under: window),
              let disabled = find("press-disabled", under: window) else { return failed("owned semantic controls missing from AX tree") }
        func unchanged() -> Bool {
            reference.remainsForeground()
                && FocusedElement.current().element.map({ CFEqual($0, focused) }) == true
                && SelectionSnapshot.read(focused) == selection
                && CGEvent(source: nil)?.location == originalCursor
        }
        // AppKit always advertises the modern press selector for these owned
        // controls. Omit only that advisory metadata through the production
        // reader seam; the action still goes to the real external AX element.
        var advisoryReads = 0
        let executor = AssistantActions(actionNamesReader: { _ in advisoryReads += 1; return [] })
        executor.begin(target: reference)
        defer { executor.cancel() }
        do {
            for (control, expectedRole) in [(button, "AXButton"), (radio, "AXRadioButton")] {
                var names: CFArray?
                let namesStatus = AXUIElementCopyActionNames(control, &names)
                let advertised = names as? [String]
                let nativeRole = string(control, kAXRoleAttribute)
                let nativeEnabled = boolean(control, kAXEnabledAttribute)
                let nativeCount = count(control)
                let nativeClick = click(control, in: reference)
                print("assistant-click-selftest metadata: role=\(nativeRole ?? "nil") enabled=\(nativeEnabled.map(String.init) ?? "nil") count=\(nativeCount.map(String.init) ?? "nil") actionStatus=\(namesStatus.rawValue) actions=\(advertised?.joined(separator: ",") ?? "nil") click=\(nativeClick != nil)")
                guard nativeRole == expectedRole, nativeEnabled == true, nativeCount == 0,
                      namesStatus == .success, advertised != nil,
                      let click = nativeClick else { return failed("owned native control metadata unavailable") }
                let readsBefore = advisoryReads
                let receipt = try await executor.execute(click, target: reference)
                guard advisoryReads >= readsBefore + 2, receipt.target.pid == pid, count(control) == 1, unchanged() else { return failed("semantic press was not applied exactly once without changing editor focus, selection or pointer") }
            }
            guard boolean(disabled, kAXEnabledAttribute) == false, count(disabled) == 0,
                  let click = click(disabled, in: reference) else { return failed("disabled fixture metadata unavailable") }
            do {
                _ = try await executor.execute(click, target: reference)
                return failed("disabled semantic control was accepted")
            } catch AssistantActionError.unsupported { /* Disabled controls must not receive AXPress. */ }
            // The fixture increments on attempted dispatch even when disabled, so zero
            // proves no activation was attempted, rather than merely no visible change.
            guard count(disabled) == 0 && count(button) == 1 && count(radio) == 1 && unchanged() else {
                return failed("disabled press attempt or changed owned editor state")
            }
            print("assistant-click-selftest: PASS: button and radio press each applied once with empty advisory action lists; disabled control untouched; editor focus, selection and pointer preserved")
            return true
        } catch { return failed("semantic click execution: \(error.localizedDescription)") }
    }
    private static func failed(_ reason: String) -> Bool {
        print("assistant-click-selftest: FAIL: \(reason)"); return false
    }
    private static func find(_ identifier: String, under root: AXUIElement) -> AXUIElement? {
        var pending = [root], examined = 0
        while !pending.isEmpty && examined < 128 {
            let current = pending.removeFirst(); examined += 1
            AXUIElementSetMessagingTimeout(current, 0.1)
            if string(current, kAXIdentifierAttribute) == identifier { return current }
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &raw) == .success,
               let children = raw as? [AXUIElement] { pending.append(contentsOf: children.prefix(32)) }
        }
        return nil
    }
    private static func click(_ control: AXUIElement, in target: AssistantWindowReference) -> BridgeAction? {
        guard let frame = target.frame, frame.width > 0, frame.height > 0 else { return nil }
        var rawPosition: CFTypeRef?, rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(control, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(control, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition, let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        guard frame.contains(point) else { return nil }
        return .init(type: "click", x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
    }
    private static func element(_ source: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func string(_ source: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    private static func boolean(_ source: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
    private static func count(_ source: AXUIElement) -> Int? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(source, kAXValueAttribute as CFString, &value) == .success,
           let number = value as? NSNumber { return number.intValue }
        // Buttons need not expose AXValue. The same owned attempt counter is also
        // published in their accessibility label, whose final token is an integer.
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] {
            if let label = string(source, attribute), label.hasPrefix("Fixture "),
               let suffix = label.split(separator: " ").last, let number = Int(suffix) { return number }
        }
        return nil
    }
}
