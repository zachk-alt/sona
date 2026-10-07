import Foundation

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored:Value
    init(_ value:Value) { stored=value }
    var value:Value { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored=newValue; lock.unlock() } }
}

@main enum AssistantLaunchDeadlineTests {
    @MainActor final class Owner { var current=true; var submissions=0 }
    enum QueuedCase:CaseIterable { case ownerCancel, taskCancel, deadline, invalidGeneration, dispatchCancel, success }
    @MainActor static func queuedLaunch(_ kind:QueuedCase) async throws {
        let owner=Owner(), waiter=AssistantCaptureDeadline<Int>()
        let queued=DispatchSemaphore(value:0), dispatch=Box<Task<Void,Never>?>(nil)
        let waiting=Task.detached {
            try await waiter.wait(seconds:kind == .deadline ? 0.03 : 2) { completion in
                dispatch.value=AssistantLaunchDispatch.enqueue(waiter:waiter,isCurrent:{ owner.current },submit:{
                    MainActor.assertIsolated()
                    owner.submissions += 1
                    completion(.success(17))
                })
                queued.signal()
            }
        }
        // Keep this actor occupied until native dispatch is definitely queued.
        precondition(queued.wait(timeout:.now()+2) == .success,"Dispatch queued before test cancellation")
        switch kind {
        case .ownerCancel: owner.current=false; waiter.cancel()
        case .taskCancel: waiting.cancel()
        case .deadline: usleep(100_000)
        case .invalidGeneration: owner.current=false
        case .dispatchCancel: dispatch.value?.cancel()
        case .success: break
        }
        await dispatch.value?.value
        if kind == .success {
            let value=try await waiting.value
            precondition(value == 17 && owner.submissions == 1,"Valid queued launch submits exactly once")
            precondition(!waiter.claimSubmission(),"Resolved launch cannot submit twice")
        } else {
            do { _ = try await waiting.value; preconditionFailure("Cancelled queued launch must fail") }
            catch is CancellationError { }
            precondition(owner.submissions == 0,"Cancelled, stale or expired queued launch submits zero times")
        }
    }
    @MainActor
    static func main() async throws {
        var count=0
        func check(_ value:Bool,_ label:String) { precondition(value,label); count += 1 }
        let immediate=try await AssistantCaptureDeadline<Int>().wait(seconds:1) { $0(.success(7)); $0(.success(9)) }
        check(immediate == 7,"First callback wins exactly once")

        let silent=AssistantCaptureDeadline<Int>(), began=ProcessInfo.processInfo.systemUptime
        do { _ = try await silent.wait(seconds:0.08) { _ in }; preconditionFailure("Silent launch must time out") }
        catch is CancellationError { count += 1 }
        check(ProcessInfo.processInfo.systemUptime-began < 0.6,"Actual silent callback timeout is bounded")

        let owner=AssistantCaptureDeadline<Int>(), callback=Box<((Result<Int,Error>)->Void)?>(nil)
        let waiting=Task { try await owner.wait(seconds:5) { callback.value=$0 } }
        while callback.value == nil { try await Task.sleep(for:.milliseconds(1)) }
        let cancelled=ProcessInfo.processInfo.systemUptime
        owner.cancel()
        do { _ = try await waiting.value; preconditionFailure("Owner cancellation must finish") }
        catch is CancellationError { count += 1 }
        check(ProcessInfo.processInfo.systemUptime-cancelled < 0.3,"Owner cancel does not wait for vendor callback")
        callback.value?(.success(99)); callback.value?(.failure(CancellationError()))
        do { _ = try await owner.wait(seconds:1) { _ in preconditionFailure("Cancelled request must not relaunch") }; preconditionFailure("Cancelled request remains cancelled") }
        catch is CancellationError { count += 1 }

        let taskWaiter=AssistantCaptureDeadline<Int>(), started=Box(false)
        let task=Task { try await taskWaiter.wait(seconds:5) { _ in started.value=true } }
        while !started.value { try await Task.sleep(for:.milliseconds(1)) }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Task cancel must finish") }
        catch is CancellationError { count += 1 }

        let before=AssistantCaptureDeadline<Int>(); before.cancel()
        do { _ = try await before.wait(seconds:1) { _ in preconditionFailure("Cancelled owner must make zero calls") }; preconditionFailure("Expected cancellation") }
        catch is CancellationError { count += 1 }

        let late=Box<((Result<Int,Error>)->Void)?>(nil)
        do { _ = try await AssistantCaptureDeadline<Int>().wait(seconds:0.03) { late.value=$0 }; preconditionFailure("Expected timeout") }
        catch is CancellationError { count += 1 }
        late.value?(.success(42))
        try await Task.sleep(for:.milliseconds(20))
        for scenario in QueuedCase.allCases { try await queuedLaunch(scenario); count += 1 }
        print("Assistant launch deadline: \(count) checks passed; real queued MainActor submission, timeout, owner/task cancellation, duplicate and late callbacks; no GUI or provider.")
    }
}
