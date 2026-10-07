import Foundation
import Darwin

/// The same cleanup bridge used by the Windows client. Node and the bridge are
/// optional: every launch, cancellation, deadline, or output failure keeps raw text.
final class BridgeCleanupService: CleanupService {
    private let configPath: String
    private let bridgePath: String
    private let nodePath: String?
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var runs: [UUID: CleanupBridgeRun] = [:]

    init(configPath: String, bridgePath: String, nodePath: String? = nil, timeout: TimeInterval = 32) {
        self.configPath = configPath
        self.bridgePath = bridgePath
        self.nodePath = Self.resolveNode(override: nodePath)
        self.timeout = timeout.isFinite ? min(35, max(1, timeout)) : 32
    }

    func prewarm(mode: CleanupMode) {}

    func clean(_ transcript: String, mode: CleanupMode) async throws -> String {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let nodePath,
              FileManager.default.isReadableFile(atPath: bridgePath),
              transcript.utf8.count <= 64 * 1024 else { return transcript }
        let run = CleanupBridgeRun(nodePath: nodePath, arguments: [bridgePath, "--config", configPath,
            "--mode", mode == .strict ? "strict" : "prose"], input: transcript, timeout: timeout)
        let id = UUID()
        add(run, id: id)
        defer { remove(id) }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: run.perform())
                }
            }
        }, onCancel: { run.cancel() })
    }

    func shutdown() {
        lock.lock()
        let active = Array(runs.values)
        lock.unlock()
        active.forEach { $0.cancel() }
    }

    private func add(_ run: CleanupBridgeRun, id: UUID) {
        lock.lock(); defer { lock.unlock() }
        runs[id] = run
    }

    private func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        runs.removeValue(forKey: id)
    }

    private static func resolveNode(override: String?) -> String? {
        if let override {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.volta/bin", "\(home)/.local/bin"]
        return directories.map { "\($0)/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Nonblocking POSIX I/O keeps both pipe directions and cancellation bounded.
/// No transcript is written to a file, argv, diagnostics, or a shell command.
final class CleanupBridgeRun: @unchecked Sendable {
    private let nodePath: String
    private let arguments: [String]
    private let input: String
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cancelled = false

    init(nodePath: String, arguments: [String], input: String, timeout: TimeInterval) {
        self.nodePath = nodePath; self.arguments = arguments; self.input = input; self.timeout = timeout
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func perform(validateGrowth: Bool = true) -> String {
        if isCancelled { return input }
        let process = Process(), inPipe = Pipe(), outPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        let writer = inPipe.fileHandleForWriting, reader = outPipe.fileHandleForReading
        let writeFD = writer.fileDescriptor, readFD = reader.fileDescriptor
        guard fcntl(writeFD, F_SETNOSIGPIPE, 1) == 0 else { return input }
        for fd in [writeFD, readFD] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return input }
        }
        defer { try? writer.close(); try? reader.close() }
        do { try process.run() } catch { return input }

        let payload = Array(input.utf8)
        var offset = 0, output = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        var writerClosed = false, outputEnded = false, failed = false
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if isCancelled || ProcessInfo.processInfo.systemUptime >= deadline { failed = true; break }
            if !writerClosed {
                let count = payload.withUnsafeBytes { bytes in
                    Darwin.write(writeFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                }
                if count > 0 { offset += count }
                else if count < 0 && errno != EAGAIN && errno != EINTR { failed = true; break }
                if offset == payload.count { try? writer.close(); writerClosed = true }
            }
            if !outputEnded {
                let count = Darwin.read(readFD, &buffer, buffer.count)
                if count > 0 {
                    output.append(contentsOf: buffer.prefix(count))
                    if output.count > 256 * 1024 { failed = true; break }
                } else if count == 0 { outputEnded = true }
                else if errno != EAGAIN && errno != EINTR { failed = true; break }
            }
            if !process.isRunning && outputEnded { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        if failed {
            if process.isRunning {
                // Node propagates this to its provider process group immediately.
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.005) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            return input
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let text = String(data: output, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (!validateGrowth || text.utf8.count <= max(input.utf8.count * 3, input.utf8.count + 40)) else { return input }
        return text
    }
}
