import Foundation

/// Cleanup via the user's already-authenticated Claude Code CLI.
///
/// The Mac economy route prewarms the existing signed-in Claude CLI.
/// Other providers and explicit models use the shared cleanup bridge.
final class ClaudeCleanupService: CleanupService {

    private let binary: String
    private let vocabulary: [String]

    private var standby: ClaudeStandby?
    private var standbyMode: CleanupMode?

    /// nil if no usable `claude` binary is on the machine.
    init?(vocabulary: [String], overridePath: String? = nil) {
        guard let binary = CLIResolver.resolve("claude", override: overridePath) else {
            return nil
        }
        self.binary = binary
        self.vocabulary = vocabulary
    }

    /// Key-DOWN. Boots a process while the user talks so its ~1.5s of startup
    /// costs nothing. Failure is silent and simply means `clean` pays for the
    /// boot itself.
    func prewarm(mode: CleanupMode) {
        if standby != nil, standbyMode == mode { return }
        shutdown()
        standby = try? ClaudeStandby(binary: binary, mode: mode, vocabulary: vocabulary)
        standbyMode = standby == nil ? nil : mode
    }

    func clean(_ transcript: String, mode: CleanupMode) async throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return transcript }

        let process: ClaudeStandby
        if let standby, standbyMode == mode {
            process = standby
        } else {
            // No usable standby: the mode changed after key-down, or the spawn
            // failed. Pay the boot cost now.
            shutdown()
            process = try ClaudeStandby(binary: binary, mode: mode, vocabulary: vocabulary)
        }
        standby = nil
        standbyMode = nil

        let cleaned = try await process.correct(trimmed)

        // A pass that returns nothing, or that balloons the text, has
        // misbehaved: most likely it answered the transcript instead of
        // repairing it. Prefer the raw words over a confident wrong answer.
        guard !cleaned.isEmpty, cleaned.count < trimmed.count * 3 else {
            throw CleanupError.badResponse("empty or oversized correction")
        }
        return cleaned
    }

    func shutdown() {
        standby?.discard()
        standby = nil
        standbyMode = nil
    }
}

/// Used when no CLI is available. Dictation still works, just without polish.
final class PassthroughCleanupService: CleanupService {
    func prewarm(mode: CleanupMode) {}
    func clean(_ transcript: String, mode: CleanupMode) async throws -> String { transcript }
    func shutdown() {}
}
