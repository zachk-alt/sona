import ApplicationServices

/// Unsupported optional attributes are different from failed reads. A busy,
/// invalid or disabled AX connection must never erase a safety attribute.
enum AssistantAXReadPolicy {
    enum Disposition { case value, absent, failed }
    static func disposition(_ result:AXError) -> Disposition {
        switch result {
        case .success: return .value
        case .attributeUnsupported, .noValue: return .absent
        default: return .failed
        }
    }
}
