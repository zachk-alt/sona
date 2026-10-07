import Foundation
import CoreGraphics

/// Pure routing and readiness rules. No process, window or content reads.
enum AssistantBrowserPolicy {
    static let identifiers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
        "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "org.mozilla.firefox", "org.mozilla.nightly", "com.brave.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
        "app.zen-browser.zen", "com.kagi.kagimacOS"
    ]
    enum Route: Equatable { case current, systemDefault, refuse }
    static func route(bundleID:String?, declaredSchemes:[String]) -> Route {
        let schemes = Set(declaredSchemes.map { $0.lowercased() })
        let handlesWeb = schemes.isSuperset(of:["http","https"])
        guard let bundleID, identifiers.contains(bundleID) else {
            // An unreviewed web handler may be a browser. Never silently move
            // its requested navigation into a different default browser.
            return handlesWeb ? .refuse : .systemDefault
        }
        return handlesWeb ? .current : .refuse
    }
}

struct AssistantWindowSettlePolicy {
    struct Window: Equatable { let id:UInt32; let frame:CGRect }
    enum Decision: Equatable { case waiting, ready, changed, timedOut }
    let originalPID:Int32
    let expectedPID:Int32
    let deadline:TimeInterval
    var stableDuration:TimeInterval = 0.35
    private var enteredExpectedApp = false
    private var candidate:Window?
    private var candidateSince:TimeInterval = 0
    init(originalPID:Int32,expectedPID:Int32,deadline:TimeInterval) {
        self.originalPID = originalPID; self.expectedPID = expectedPID; self.deadline = deadline
    }
    mutating func observe(now:TimeInterval,foregroundPID:Int32?,window:Window?,activityUnchanged:Bool) -> Decision {
        guard activityUnchanged else { return .changed }
        guard now < deadline else { return .timedOut }
        guard let foregroundPID else { candidate = nil; return .waiting }
        if foregroundPID != expectedPID {
            candidate = nil
            return !enteredExpectedApp && foregroundPID == originalPID ? .waiting : .changed
        }
        enteredExpectedApp = true
        guard let window, window.frame.width > 1, window.frame.height > 1,
              [window.frame.origin.x,window.frame.origin.y,window.frame.width,window.frame.height].allSatisfy(\.isFinite) else {
            candidate = nil; return .waiting
        }
        if candidate != window { candidate = window; candidateSince = now; return .waiting }
        return now - candidateSince >= stableDuration ? .ready : .waiting
    }
}

/// AX action lists are advisory. Only known, enabled button roles qualify
/// when AXPress is omitted; actual AX success remains mandatory.
enum AssistantClickPolicy {
    static func canPress(role:String,advertised:[String],enabled:Bool?) -> Bool {
        guard enabled != false else { return false }
        if advertised.contains("AXPress") { return true }
        return enabled == true && ["AXButton","AXRadioButton"].contains(role)
    }
}

/// Standard Apple Maps links stay in the Maps window that owns this task.
/// This route does not handle arbitrary URL schemes or switch other apps.
enum AssistantMapLinkPolicy {
    static func refusesFallback(url:URL,bundleID:String?) -> Bool {
        bundleID == "com.apple.Maps" && url.host?.lowercased() == "maps.apple.com"
            && !usesCurrentMaps(url:url,bundleID:bundleID)
    }
    static func usesCurrentMaps(url:URL,bundleID:String?) -> Bool {
        guard bundleID == "com.apple.Maps", let parts = URLComponents(url:url,resolvingAgainstBaseURL:false),
              ["http","https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.lowercased() == "maps.apple.com", parts.user == nil, parts.password == nil,
              parts.fragment == nil, ["","/"].contains(parts.path),
              parts.port == nil || (parts.scheme?.lowercased() == "https" ? parts.port == 443 : parts.port == 80) else { return false }
        return parts.queryItems?.contains(where: { ["q","daddr","address","ll"].contains($0.name) && !($0.value?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true) }) == true
    }
}
