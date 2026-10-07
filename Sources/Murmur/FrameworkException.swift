import Foundation
import SonaObjC

/// An Objective-C exception raised by a framework call, rethrown as a Swift error.
struct FrameworkException: Error, CustomStringConvertible {
    let name: String
    let reason: String

    /// Logged by every catch site. AVFAudio reasons describe formats and
    /// nodes, never dictated text; other frameworks' reasons can quote app
    /// text, so only the name is kept for them. Capped so a log line stays a line.
    var description: String {
        name.hasPrefix("com.apple.coreaudio") ? "\(name): \(reason.prefix(200))" : name
    }
}

/// Runs one framework call that may raise an Objective-C exception and turns
/// that exception into a thrown `FrameworkException`. Swift errors thrown by
/// `body` pass through unchanged.
///
/// Swift cannot catch NSException. Raised in a main-actor task, AppKit
/// swallows it and the main dispatch queue never runs again, so the hotkey,
/// the panel and every async session go silent while the menu bar icon still
/// looks alive; raised in a plain main-queue block, the app aborts. Wrap only
/// the single framework call that can raise; nothing in `body` should need
/// cleanup on unwind.
func catchingFrameworkException<T>(_ body: () throws -> T) throws -> T {
    var result: Result<T, Error>?
    if let exception = SonaCatchException({ result = Result { try body() } }) {
        throw FrameworkException(name: exception.name.rawValue, reason: exception.reason ?? "")
    }
    guard let result else { throw FrameworkException(name: "unknown", reason: "no result") }
    return try result.get()
}
