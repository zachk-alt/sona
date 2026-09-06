import Foundation
import ServiceManagement

/// Launch-at-login, via SMAppService.
///
/// A dictation hotkey that is not running when you reach for the key is a
/// dictation hotkey you stop using, so this defaults to on. It is a standing
/// process holding an event tap and microphone access, which is a deliberate
/// choice rather than an accident: the tap is scoped to modifier transitions
/// and the microphone is opened only while recording.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True if the state now matches what was asked for.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                // `register` throws if already registered, which is not a failure.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }

    /// Install maintenance after moving the signed app. Keep the user's
    /// existing choice: disabled or approval-pending services are untouched.
    @discardableResult
    static func refreshRegistrationIfEnabled() throws -> Bool {
        let service = SMAppService.mainApp
        guard service.status == .enabled else { return false }
        // Unregistering a main-app login item leaves this process running.
        try service.unregister()
        try service.register()
        guard service.status == .enabled else {
            throw NSError(domain: "dev.murmur.Murmur.login", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Login item did not remain enabled after refreshing its path."])
        }
        return true
    }

    /// Registration records the app's current path. Launching from a build
    /// directory means the login item breaks the moment the folder moves, so
    /// the menu says so rather than silently pointing at a stale location.
    static var isInStableLocation: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications")
    }
}
