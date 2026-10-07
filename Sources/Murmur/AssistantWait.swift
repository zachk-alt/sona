import Foundation

/// Loading can be observed again without submitting another input event.
/// Each wait remains one step in the existing assistant action budget.
enum AssistantWait {
    enum Failure: Error { case invalidDuration }
    @MainActor
    static func run(milliseconds: Int, validate: () throws -> Void) async throws {
        guard (250...1500).contains(milliseconds) else { throw Failure.invalidDuration }
        let deadline = ContinuousClock.now + .milliseconds(milliseconds)
        try Task.checkCancellation()
        try validate()
        while ContinuousClock.now < deadline {
            let remaining = ContinuousClock.now.duration(to: deadline)
            if remaining > .zero { try await Task.sleep(for: min(.milliseconds(50), remaining)) }
            try Task.checkCancellation()
            try validate()
        }
    }
}
