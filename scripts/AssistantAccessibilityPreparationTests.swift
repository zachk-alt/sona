import Foundation

@main
struct AssistantAccessibilityPreparationTests {
    enum Failure: Error { case changed }
    @MainActor
    static func main() async throws {
        var checks = 0
        func require(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        let preparation = AssistantAccessibilityPreparation()
        var enabled: [Int32] = []
        var validations = 0
        func prepare(_ pid: Int32) async throws {
            try await preparation.prepare(pid:pid,validate:{ validations += 1 },enable:{ enabled.append(pid) },settle:{})
        }
        try await prepare(11)
        require(enabled == [11] && validations == 2,"First target must enable and validate on both sides.")
        try await prepare(11)
        require(enabled == [11] && validations == 3,"Repeated target must validate without toggling again.")
        try await prepare(22)
        try await prepare(11)
        require(enabled == [11,22,11],"A later app and a return to an earlier app must re-enable.")
        preparation.cancel()
        try await prepare(11)
        require(enabled == [11,22,11,11],"A new action session must prepare again.")

        var invalidSubmissions = 0
        do {
            try await preparation.prepare(pid:33,validate:{ throw Failure.changed },enable:{ invalidSubmissions += 1 },settle:{})
            preconditionFailure("Changed target must stop.")
        } catch Failure.changed {}
        require(invalidSubmissions == 0,"A changed target must submit zero preparations.")

        let cancelled = Task { @MainActor in
            try await preparation.prepare(pid:33,validate:{},enable:{ invalidSubmissions += 1 },settle:{})
        }
        cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("Cancelled task must stop.") }
        catch is CancellationError {}
        require(invalidSubmissions == 0,"Cancellation before actor dispatch must submit zero preparations.")

        var lateValidationCount = 0
        do {
            try await preparation.prepare(pid:44,validate:{ lateValidationCount += 1 },enable:{},settle:{ preparation.cancel() })
            preconditionFailure("Owner cancellation must reject late preparation.")
        } catch is CancellationError {}
        require(lateValidationCount == 1,"Cancelled completion must not become prepared.")
        try await prepare(44)
        require(enabled.last == 44,"A cancelled preparation must be retried only on a later explicit call.")

        var targetCurrent = true
        do {
            try await preparation.prepare(pid:55,validate:{ if !targetCurrent { throw Failure.changed } },enable:{},settle:{ targetCurrent = false })
            preconditionFailure("Target change during wait must stop.")
        } catch Failure.changed {}
        targetCurrent = true
        try await prepare(55)
        require(enabled.last == 55,"A target changed during settling must not be cached.")

        var entered = false
        let started = ContinuousClock.now
        let waiting = Task { @MainActor in
            try await preparation.prepare(pid:66,validate:{},enable:{ entered = true })
        }
        while !entered { await Task.yield() }
        waiting.cancel()
        do { try await waiting.value; preconditionFailure("Sleep must be cancellable.") }
        catch is CancellationError {}
        require(entered && started.duration(to:.now) < .seconds(1),"Cancellation after preparation starts must throw within a bounded second.")

        var mainActorRan = false
        let elapsedStart = ContinuousClock.now
        let natural = Task { @MainActor in
            try await preparation.prepare(pid:77,validate:{},enable:{})
        }
        let concurrent = Task { @MainActor in mainActorRan = true }
        await concurrent.value
        try await natural.value
        let elapsed = elapsedStart.duration(to:.now)
        require(mainActorRan && elapsed >= .milliseconds(140) && elapsed < .seconds(1),"Default settling must be bounded and release the main actor.")
        print("Assistant accessibility preparation: \(checks) checks passed; no AX calls, GUI or provider.")
    }
}
