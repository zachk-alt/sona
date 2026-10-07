import Foundation

/// Some apps create their accessibility tree only after the client opts in.
/// Remember only the latest app in this action session, never UI content.
@MainActor
final class AssistantAccessibilityPreparation {
    private var preparedPID: Int32?
    private var revision: UInt64 = 0

    func cancel() {
        revision &+= 1
        preparedPID = nil
    }

    func prepare(pid: Int32, validate: () throws -> Void, enable: () -> Void,
                 settle: () async throws -> Void = { try await Task.sleep(for: .milliseconds(150)) }) async throws {
        try Task.checkCancellation()
        try validate()
        guard preparedPID != pid else { return }
        revision &+= 1
        let attempt = revision
        preparedPID = nil
        // Validation and submission share one actor turn. Cancellation before
        // this point submits nothing; enabling accessibility sends no input.
        enable()
        try await settle()
        try Task.checkCancellation()
        guard revision == attempt else { throw CancellationError() }
        try validate()
        preparedPID = pid
    }
}
