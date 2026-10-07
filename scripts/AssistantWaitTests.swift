import Foundation

@main struct AssistantWaitTests {
    enum Changed: Error { case target }
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { fatalError(name) }
        }
        for duration in [-1, 0, 249, 1501, Int.max] {
            var observed = false
            do {
                try await AssistantWait.run(milliseconds: duration) { observed = true }
                fatalError("invalid duration accepted")
            } catch AssistantWait.Failure.invalidDuration { }
            check(!observed, "invalid duration performs no observation")
        }
        let start = ContinuousClock.now
        var validations = 0
        try await AssistantWait.run(milliseconds: 250) { validations += 1 }
        check(start.duration(to: .now) >= .milliseconds(250), "wait actually yields before next observation")
        check((2...6).contains(validations), "foreground guard runs before and throughout wait")
        let slowStart = ContinuousClock.now
        try await AssistantWait.run(milliseconds: 250) { Thread.sleep(forTimeInterval: 0.1) }
        check(slowStart.duration(to: .now) < .milliseconds(650), "validation latency consumes the wait budget instead of extending every slice")
        var staleReads = 0
        do {
            try await AssistantWait.run(milliseconds: 1500) {
                staleReads += 1
                if staleReads == 2 { throw Changed.target }
            }
            fatalError("changed target accepted")
        } catch Changed.target { }
        check(staleReads == 2, "changed target stops further observation")
        var cancellationReads = 0
        let task = Task { @MainActor in
            try await AssistantWait.run(milliseconds: 1500) { cancellationReads += 1 }
        }
        while cancellationReads == 0 { await Task.yield() }
        task.cancel()
        do { try await task.value; fatalError("cancelled wait completed") }
        catch is CancellationError { }
        check(cancellationReads == 1, "closing conversation cancels before another guard read")
        print("PASS: \(checks) bounded wait, cancellation and target-change checks")
    }
}
