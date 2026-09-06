import Foundation

/// Newline-delimited reads off a pipe, exposed as an async sequence of lines.
///
/// `FileHandle.availableData` blocks, so the read loop gets its own thread and
/// hands completed lines back through a continuation.
final class LineReader {

    private let handle: FileHandle
    private let lock = NSLock()

    private var pending: [String] = []
    private var buffer = Data()
    private var finished = false
    private var waiter: CheckedContinuation<String?, Never>?

    init(handle: FileHandle) {
        self.handle = handle
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "murmur.linereader"
        thread.start()
    }

    private func readLoop() {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }        // EOF

            lock.lock()
            if finished { lock.unlock(); return }
            buffer.append(chunk)

            var delivered: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let line = String(decoding: lineData, as: UTF8.self)
                if !line.isEmpty { delivered.append(line) }
            }
            pending.append(contentsOf: delivered)
            let next = takeWaiterAndLine_locked()
            lock.unlock()
            next?.0.resume(returning: next?.1)
        }

        lock.lock()
        finished = true
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: nil)
    }

    /// Caller must hold `lock`.
    private func takeWaiterAndLine_locked() -> (CheckedContinuation<String?, Never>, String)? {
        guard let continuation = waiter, !pending.isEmpty else { return nil }
        waiter = nil
        return (continuation, pending.removeFirst())
    }

    /// Next line, or nil once the pipe closes. Cancellation stops this reader.
    func nextLine() async throws -> String? {
        let line = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                lock.lock()
                if !pending.isEmpty {
                    let line = pending.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: line)
                    return
                }
                if finished {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                // Only one consumer is ever in flight: requests are serialized by
                // the daemon, one dictation at a time.
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            // A task group must be able to finish even if the child never writes.
            self.stop()
        }
        try Task.checkCancellation()
        return line
    }

    func stop() {
        lock.lock()
        finished = true
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: nil)
        try? handle.close()
    }
}
