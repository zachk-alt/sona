import AppKit
import ApplicationServices
import Foundation

/// Keyboard focus and the identity retained for one dictation session.
enum FocusedElement {
    struct Result {
        let element: AXUIElement?
        let error: AXError
        let app: String
        let pid: pid_t?

        init(element: AXUIElement?, error: AXError, app: String, pid: pid_t? = nil) {
            self.element = element
            self.error = error
            self.app = app
            self.pid = pid
        }
    }

    /// These references and optional document metadata remain in memory only.
    struct Target {
        let pid: pid_t
        let element: AXUIElement?
        let window: AXUIElement?
        let document: String?
        let windowTitle: String?
    }

    enum Match: String {
        case same, applicationChanged, fieldChanged, windowChanged, documentChanged, unavailable
    }

    static func captureTarget() -> Target? {
        let focus = current()
        guard let pid = focus.pid, pid > 0 else { return nil }
        guard let element = focus.element, isConcreteEditableField(element) else {
            return Target(pid: pid, element: nil, window: nil, document: nil, windowTitle: nil)
        }
        let window = elementAttribute(element, kAXWindowAttribute)
        let document = stringAttribute(element, kAXDocumentAttribute)
            ?? window.flatMap { stringAttribute($0, kAXDocumentAttribute) }
        let title = window.flatMap { stringAttribute($0, kAXTitleAttribute) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        return Target(pid: pid, element: element, window: window, document: document, windowTitle: title)
    }

    /// Pure identity comparison also used by the headless insertion tests.
    static func match(_ original: Target?, _ current: Target?) -> Match {
        guard let original, let current else { return .unavailable }
        guard original.pid == current.pid else { return .applicationChanged }
        guard let before = original.element, let after = current.element else { return .unavailable }
        guard CFEqual(before, after) else { return .fieldChanged }
        switch (original.window, current.window) {
        case let (before?, after?):
            guard CFEqual(before, after) else { return .windowChanged }
        case (nil, nil): break
        default: return .unavailable
        }
        guard original.document == current.document, original.windowTitle == current.windowTitle else {
            return .documentChanged
        }
        return .same
    }

    private static func isConcreteEditableField(_ element: AXUIElement) -> Bool {
        guard stringAttribute(element, kAXSubroleAttribute) != "AXSecureTextField" else { return false }
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return true }
        // A coarse Electron/web container can remain focused while its real field changes.
        guard !["", "AXGroup", "AXWebArea", "AXWindow", "AXApplication"].contains(role) else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return false }
        return (names as? [String])?.contains(kAXSelectedTextRangeAttribute) == true
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let result = value as! AXUIElement
        AXUIElementSetMessagingTimeout(result, 0.2)
        return result
    }

    /// Ask the frontmost app first, enabling Electron's accessibility tree, then
    /// use the system-wide fallback. A result must still belong to that same app.
    static func current() -> Result {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return Result(element: nil, error: .noValue, app: "?")
        }
        let pid = app.processIdentifier
        let appName = app.bundleIdentifier ?? app.localizedName ?? "?"
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var lastError: AXError = .failure

        func checked(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
            let element = value as! AXUIElement
            var elementPID: pid_t = 0
            guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == pid else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.2)
            return element
        }

        for attempt in 0..<2 {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value)
            if error == .success, let element = checked(value) {
                return Result(element: element, error: .success, app: appName, pid: pid)
            }
            lastError = error == .success ? .noValue : error
            if error == .noValue { break }
            if attempt == 0 { usleep(30_000) }
        }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        if error == .success, let element = checked(value) {
            return Result(element: element, error: .success, app: appName, pid: pid)
        }
        return Result(element: nil, error: lastError == .failure ? error : lastError, app: appName, pid: pid)
    }
}
