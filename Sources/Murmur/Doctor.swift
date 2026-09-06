import AppKit
import AVFoundation
import ApplicationServices
import Foundation
import ServiceManagement
import Speech

/// `Murmur --doctor`
///
/// Every check here must run from inside the app bundle. Permission APIs and
/// SMAppService answer for the CALLING bundle, so the same code run from a
/// loose binary reports a different, useless answer.
enum Doctor {

    static func run() async -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String, fatal: Bool = true) {
            let mark = ok ? "ok  " : (fatal ? "FAIL" : "warn")
            if !ok && fatal { failures += 1 }
            print("  [\(mark)] \(name): \(detail)")
        }

        print("Sona doctor")
        print("  bundle: \(Bundle.main.bundleURL.path)")
        print("  id:     \(Bundle.main.bundleIdentifier ?? "<none>")")
        print("")

        // Accessibility gates BOTH halves of the app: reading the hotkey and
        // typing text into another process.
        check("Accessibility", AXIsProcessTrusted(),
              AXIsProcessTrusted()
                ? "granted"
                : "NOT granted. System Settings > Privacy & Security > Accessibility.")

        check("Post-event access", CGPreflightPostEventAccess(),
              CGPreflightPostEventAccess()
                ? "granted (what the hotkey tap actually needs)"
                : "NOT granted")

        // tapCreate is deliberately NOT checked. It succeeds without any
        // permission and then delivers nothing, so a non-nil tap proves nothing.

        // The app's own launch line is the only answer that reflects the app's
        // grants rather than this terminal's.
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Murmur.log")
        if let log = try? String(contentsOf: logURL, encoding: .utf8),
           let last = log.split(separator: "\n").last(where: { $0.contains("launch:") }) {
            print("  [info] app's own last launch: \(last)")
        }
        print("  [info] Permission answers here are for THIS process. From a terminal they")
        print("         reflect the terminal's grants. The launch line above is the app's truth.")

        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let micNames: [AVAuthorizationStatus: String] = [
            .authorized: "granted", .denied: "DENIED",
            .restricted: "restricted", .notDetermined: "not yet asked (prompts on first dictation)"]
        check("Microphone", mic == .authorized || mic == .notDetermined,
              micNames[mic] ?? "unknown")

        check("SpeechTranscriber", SpeechTranscriber.isAvailable,
              SpeechTranscriber.isAvailable ? "available" : "unavailable on this OS")

        let installed = await SpeechTranscriber.installedLocales
        let english = installed.filter { $0.identifier.hasPrefix("en") }
        check("Speech model", !english.isEmpty,
              english.isEmpty
                ? "no English locale installed"
                : "\(english.count) English locales on disk, no download needed")

        let config = Config.load()
        let claude = CLIResolver.resolve("claude", override: config.claudePath)
        check("Claude CLI", claude != nil,
              claude ?? "not found. Dictation still works, cleanup is skipped.",
              fatal: false)
        check("Vocabulary", !config.vocabulary.isEmpty,
              config.vocabulary.isEmpty
                ? "empty. Add your jargon to \(Config.configURL.path)"
                : "\(config.vocabulary.count) terms",
              fatal: false)

        let statusNames: [SMAppService.Status: String] = [
            .notRegistered: "off", .enabled: "on",
            .requiresApproval: "BLOCKED, approve in System Settings > General > Login Items",
            .notFound: "not found"]
        let loginStatus = SMAppService.mainApp.status
        check("Open at login", loginStatus == .enabled,
              statusNames[loginStatus] ?? "unknown",
              fatal: false)
        if !LoginItem.isInStableLocation {
            print("  [warn] Bundle is outside /Applications. A login item here breaks when the folder moves.")
        }

        print("")
        print(failures == 0 ? "  READY." : "  \(failures) blocking problem(s).")
        return failures == 0 ? 0 : 1
    }
}
