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
        var windowID: CGWindowID? = nil
        var activity: Activity? = nil
        var blocked: Bool = false
    }

    struct Activity: Equatable {
        let session: UUID
        var revision: UInt64
    }

    private static var activity: Activity?
    private static var activityMonitor: Any?
    private static var activationMonitor: NSObjectProtocol?

    /// Only active during a dictation. Keep an activity counter, never keys or text.
    /// Global monitors exclude clicks in Sona's own nonactivating Done panel.
    static func beginTrackingActivity(ignoringKey: @escaping (NSEvent) -> Bool) {
        endTrackingActivity()
        guard AXIsProcessTrusted() else { return }
        activity = Activity(session: UUID(), revision: 0)
        activityMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { event in
                if event.type == .keyDown && ignoringKey(event) { return }
                activity?.revision &+= 1
            }
        activationMonitor = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
                activity?.revision &+= 1
            }
    }

    static func endTrackingActivity() {
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        if let activationMonitor { NSWorkspace.shared.notificationCenter.removeObserver(activationMonitor) }
        activityMonitor = nil
        activationMonitor = nil
        activity = nil
    }

    enum Match: String {
        case same, applicationChanged, fieldChanged, windowChanged, documentChanged, activityChanged, blocked, unavailable
    }

    static func captureTarget(focus suppliedFocus: Result? = nil) -> Target? {
        let token = activityMonitor != nil && AXIsProcessTrusted() ? activity : nil
        let focus = suppliedFocus ?? current()
        guard let pid = focus.pid, pid > 0 else { return nil }
        let element = focus.element
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        let window = element.flatMap { elementAttribute($0, kAXWindowAttribute) }
            ?? elementAttribute(appElement, kAXFocusedWindowAttribute)
        let document = element.flatMap { stringAttribute($0, kAXDocumentAttribute) }
            ?? window.flatMap { stringAttribute($0, kAXDocumentAttribute) }
        let title = window.flatMap { stringAttribute($0, kAXTitleAttribute) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        return Target(pid: pid, element: element.flatMap { isConcreteEditableField($0) ? $0 : nil },
                      window: window, document: document, windowTitle: title,
                      windowID: frontWindowID(pid: pid), activity: token,
                      blocked: element.map(isKnownNonEditableField) ?? false)
    }

    /// Pure identity comparison also used by the headless insertion tests.
    static func match(_ original: Target?, _ current: Target?) -> Match {
        guard let original, let current else { return .unavailable }
        guard original.pid == current.pid else { return .applicationChanged }
        guard !original.blocked, !current.blocked else { return .blocked }
        guard let before = original.element, let after = current.element else {
            // Some Electron editors expose no focused AX field at all. The same
            // window and an uninterrupted user gesture still provide a usable
            // paste destination. A click, key, or app switch invalidates it.
            guard let activity = original.activity, let currentActivity = current.activity else { return .unavailable }
            guard activity == currentActivity else { return .activityChanged }
            if let before = original.windowID, let after = current.windowID {
                guard before != 0, after != 0 else { return .unavailable }
                guard before == after else { return .windowChanged }
            } else {
                guard let before = original.window, let after = current.window else { return .unavailable }
                guard CFEqual(before, after) else { return .windowChanged }
            }
            if let before = original.window, let after = current.window, !CFEqual(before, after) { return .windowChanged }
            guard original.document == current.document else { return .documentChanged }
            return .same
        }
        guard CFEqual(before, after) else { return .fieldChanged }
        switch (original.window, current.window) {
        case let (before?, after?):
            guard CFEqual(before, after) else { return .windowChanged }
        case (nil, nil): break
        default: return .unavailable
        }
        guard original.document == current.document else { return .documentChanged }
        if original.document == nil && original.windowTitle != current.windowTitle { return .documentChanged }
        return .same
    }

    /// Window metadata only. No screenshots, titles, or screen permission needed.
    private static func frontWindowID(pid: pid_t) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value, number != 0 else { continue }
            return number
        }
        return nil
    }

    private static func isKnownNonEditableField(_ element: AXUIElement) -> Bool {
        if stringAttribute(element, kAXSubroleAttribute) == "AXSecureTextField" { return true }
        return ["AXStaticText", "AXSlider", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXButton",
                "AXMenuItem", "AXMenu", "AXMenuBar", "AXScrollBar", "AXImage", "AXLink", "AXTable",
                "AXOutline", "AXRow", "AXCell", "AXList", "AXIncrementor", "AXDisclosureTriangle",
                "AXToolbar", "AXTabGroup", "AXColorWell", "AXProgressIndicator"]
            .contains(stringAttribute(element, kAXRoleAttribute) ?? "")
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
