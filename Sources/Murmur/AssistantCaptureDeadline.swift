import Foundation

/// A one-shot callback may finish after ScreenCaptureKit's client deadline.
/// Resolve once, release its waiter, and discard late images without saving them.
final class AssistantCaptureDeadline<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value,Error>?
    private var resolved: Result<Value,Error>?
    private var timeout: DispatchWorkItem?
    private var submissionClaimed = false
    /// Explicit owner cancellation also releases waiters when their Task is
    /// still running, for example while NSWorkspace is waiting on launch UI.
    func cancel() { finish(.failure(CancellationError())) }
    /// Establish submission ordering against cancellation and timeout. The
    /// caller dispatches immediately after this claim, without an actor yield.
    /// Never hold this lock while invoking a vendor callback API.
    func claimSubmission() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard continuation != nil, resolved == nil, !submissionClaimed else { return false }
        submissionClaimed = true
        return true
    }
    func wait(seconds:Double,start:@escaping(@escaping(Result<Value,Error>)->Void)->Void) async throws -> Value {
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let resolved { lock.unlock(); continuation.resume(with:resolved); return }
                self.continuation = continuation
                let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(CancellationError())) }
                timeout = timer; lock.unlock()
                DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+seconds,execute:timer)
                start { [weak self] result in self?.finish(result) }
            }
        },onCancel:{ self.finish(.failure(CancellationError())) })
    }
    private func finish(_ result:Result<Value,Error>) {
        lock.lock()
        guard resolved == nil else { lock.unlock(); return }
        resolved = result
        let continuation = self.continuation; self.continuation = nil
        let timeout = self.timeout; self.timeout = nil
        lock.unlock(); timeout?.cancel(); continuation?.resume(with:result)
    }
}
