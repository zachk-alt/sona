import AppKit
import ApplicationServices

struct SelectionContents: Equatable {
    let range: NSRange
    let text: String
    let characterCount: Int?
    var isEmpty: Bool { range.length == 0 && text.isEmpty }
    static func ==(lhs:Self,rhs:Self) -> Bool {
        lhs.range == rhs.range && lhs.characterCount == rhs.characterCount && lhs.text.utf16.elementsEqual(rhs.text.utf16)
    }
}
struct SelectionSnapshot {
    let target: FocusedElement.Target
    let contents: SelectionContents

    static func capture() -> SelectionSnapshot? {
        guard let target = FocusedElement.captureTarget(), target.activity != nil, !target.blocked, let element = target.element,
              let contents = read(element) else { return nil }
        return .init(target:target,contents:contents)
    }
    /// Observation preflight reads metadata only, never existing field text.
    static func emptyFieldBaseline() -> SelectionSnapshot? {
        guard let target = FocusedElement.captureTarget(), target.activity != nil, !target.blocked,
              let element = target.element else { return nil }
        AXUIElementSetMessagingTimeout(element,0.08)
        guard isWritable(element), (attribute(element,kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue == 0,
              let value = attribute(element,kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue,.cfRange,&range), range.location == 0, range.length == 0 else { return nil }
        return .init(target:target,contents:.init(range:NSRange(location:0,length:0),text:"",characterCount:0))
    }
    func matchesNow() -> Bool {
        guard let current = FocusedElement.captureTarget(), target.element != nil, current.element != nil,
              target.activity != nil, target.activity == current.activity,
              FocusedElement.match(target,current) == .same,
              let element = current.element, let now = Self.read(element) else { return false }
        return validates(current:current,contents:now)
    }
    func validates(current:FocusedElement.Target,contents now:SelectionContents) -> Bool {
        target.element != nil && current.element != nil && target.activity != nil
            && target.activity == current.activity && FocusedElement.match(target,current) == .same
            && contents == now
    }
    /// No AXValue/full-document read. The selected text is bounded before fetching it.
    static func read(_ element: AXUIElement) -> SelectionContents? {
        AXUIElementSetMessagingTimeout(element,0.08)
        guard isWritable(element) else { return nil }
        if let enabled = attribute(element,kAXEnabledAttribute) as? Bool, !enabled { return nil }
        if let ranges = attribute(element,kAXSelectedTextRangesAttribute) as? [AXValue], ranges.count > 1 { return nil }
        guard let value = attribute(element,kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue,.cfRange,&range), range.location >= 0, range.length >= 0,
              range.length <= 32768, range.location <= Int.max - range.length else { return nil }
        let count = (attribute(element,kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
        if let count, count < range.location + range.length { return nil }
        let nsRange = NSRange(location:range.location,length:range.length)
        guard let text = string(element,range:nsRange), text.utf16.count == range.length,
              text.utf8.count <= 64 * 1024 else { return nil }
        guard let after = attribute(element,kAXSelectedTextRangeAttribute), CFGetTypeID(after) == AXValueGetTypeID() else { return nil }
        var afterRange = CFRange()
        guard AXValueGetValue(after as! AXValue,.cfRange,&afterRange), afterRange.location == range.location, afterRange.length == range.length else { return nil }
        return .init(range:nsRange,text:text,characterCount:count)
    }
    static func isWritable(_ element:AXUIElement) -> Bool {
        var writable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element,kAXValueAttribute as CFString,&writable) == .success && writable.boolValue
    }
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else { return nil }
        return value
    }
    static func string(_ element: AXUIElement, range: NSRange) -> String? {
        guard range.location >= 0, range.length >= 0, range.length <= 32768 else { return nil }
        var r = CFRange(location:range.location,length:range.length)
        guard let value = AXValueCreate(.cfRange,&r) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element,kAXStringForRangeParameterizedAttribute as CFString,value,&result) == .success else { return nil }
        return result as? String
    }
}
