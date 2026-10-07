import Foundation

/// Diagnostic output is built from fixed categories. Unrecognized AX role
/// strings are never emitted, and this formatter accepts no labels or values.
enum AssistantClickDiagnostics {
    enum Phase:String { case initial, recheck, apply }
    enum Reason:String {
        case hitTestFailed="hit_test_failed"
        case disabledControl="disabled_control"
        case noSemanticTarget="no_semantic_target"
        case parentDepthExhausted="parent_depth_exhausted"
        case pressFailed="ax_press_failed"
        case focusFailed="ax_focus_failed"
        case searchDeadline="search_deadline"
        case parentCycle="parent_cycle"
        case windowBoundary="window_boundary"
        case secureControl="secure_control"
        case metadataReadFailed="metadata_read_failed"
    }
    private static let roles:Set<String> = [
        "AXApplication","AXWindow","AXSheet","AXDrawer","AXPopover",
        "AXButton","AXRadioButton","AXCheckBox","AXLink","AXGroup",
        "AXStaticText","AXImage","AXWebArea","AXScrollArea","AXList",
        "AXRow","AXCell","AXToolbar","AXMenu","AXMenuItem","AXTabGroup",
        "AXTextField","AXTextArea","AXComboBox","AXSearchField","AXUnknown"
    ]
    static func line(reason:Reason,phase:Phase,depth:Int,role:String?,axResult:Int32?=nil) -> String {
        let roleName=role.map { roles.contains($0) ? $0 : "other" } ?? "unavailable"
        let result=axResult.map(String.init) ?? "none"
        return "assistant: native_click_failure action=click phase=\(phase.rawValue) reason=\(reason.rawValue) depth=\(min(12,max(0,depth))) role=\(roleName) ax=\(result)"
    }
}
