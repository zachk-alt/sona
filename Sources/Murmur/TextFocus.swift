import ApplicationServices
import Foundation

/// Answers one question: is the user's cursor in something that accepts
/// typing right now?
///
/// Right Command is an ordinary modifier the user needs for shortcuts. If
/// nothing typeable has focus, a press should do nothing at all: no sound, no
/// mic, no panel. Costs a few ms of Accessibility calls at press time.
enum TextFocus {

    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    /// Roles a text cursor cannot be inside. These are the ONLY refusals.
    /// Containers (AXGroup, AXWebArea, AXWindow...) are deliberately absent:
    /// a Chromium app with a half-built accessibility tree reports the
    /// container instead of the editor inside it, and refusing on that would
    /// block dictation in Chrome, VS Code and Slack.
    private static let neverText: Set<String> = [
        "AXStaticText", "AXSlider", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXButton", "AXMenuItem", "AXMenu", "AXMenuBar",
        "AXScrollBar", "AXImage", "AXLink", "AXTable", "AXOutline", "AXRow",
        "AXCell", "AXList", "AXIncrementor", "AXDisclosureTriangle",
        "AXToolbar", "AXTabGroup", "AXColorWell", "AXProgressIndicator",
    ]

    /// `certain` is false whenever the answer is not a positive identification.
    /// Callers treat that as "go ahead": a flaky or coarse answer must never
    /// block the user. Measured: VS Code reports "nothing focused" (AXError
    /// noValue) while the user is typing in it.
    static func probe() -> (accepts: Bool, certain: Bool, description: String) {
        let focus = FocusedElement.current()
        guard let element = focus.element else {
            return (true, false, "\(focus.app) says AXError \(focus.error.rawValue)")
        }

        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        let description = (subrole.isEmpty ? role : "\(role)/\(subrole)") + " in \(focus.app)"

        // Never dictate into a password field.
        if subrole == "AXSecureTextField" { return (false, true, "\(description) (password)") }
        if textRoles.contains(role) { return (true, true, description) }
        if neverText.contains(role) { return (false, true, description) }
        if role.isEmpty { return (true, false, "no role in \(focus.app)") }

        // Custom editors and editable web content: a settable value plus a
        // selected-text range is what "you can type here" looks like.
        var settable = DarwinBoolean(false)
        let valueSettable =
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
        var namesRef: CFArray?
        let hasRange =
            AXUIElementCopyAttributeNames(element, &namesRef) == .success
            && ((namesRef as? [String])?.contains(kAXSelectedTextRangeAttribute as String) ?? false)
        // Editable: certain yes. Not editable but a container: not certain,
        // so allow. Only the explicit list above ever refuses.
        return valueSettable && hasRange ? (true, true, description) : (true, false, description)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return "" }
        return ref as? String ?? ""
    }
}
