import Foundation

/// App opening must share the owner's actor. A cancelled or expired callback
/// waiter can remain queued here, but it must not submit a native launch.
enum AssistantLaunchDispatch {
    @discardableResult
    static func enqueue<Value>(waiter:AssistantCaptureDeadline<Value>,
        isCurrent:@escaping @MainActor () -> Bool,
        submit:@escaping @MainActor () -> Void) -> Task<Void,Never> {
        Task { @MainActor in
            guard !Task.isCancelled, isCurrent(), waiter.claimSubmission() else {
                waiter.cancel()
                return
            }
            // No suspension between the current-owner check and submission.
            // Cancellation after the claim cannot undo an OS launch request.
            submit()
        }
    }
}
