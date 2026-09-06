import Foundation
import Darwin

/// One `claude` process, pre-warmed, used for exactly one correction.
///
/// Spawned on key-DOWN so that it boots while the user is still speaking, which
/// makes its startup free. On key-UP it takes one message and is then discarded.
///
/// Measured on an M1 (claude 2.1.257, claude-haiku-4-5, n>=5 per variant):
///   naive `claude -p --model haiku` ......... 10.79s median   unusable
///   + MAX_THINKING_TOKENS=0 alone ............ 6.85s median   still unusable
///   + custom system prompt + --tools "" ...... 1.45s median   viable
///   + pre-warmed on key-down ................. 0.99s median   ships
///
/// Three knobs are each necessary and none is sufficient alone:
///   --system-prompt        replaces Claude Code's ~29K-token agent prompt
///   --tools ""             drops the tool definitions
///   MAX_THINKING_TOKENS=0  stops Haiku spending ~1200 thinking tokens
///                          deliberating over a spelling fix
///
/// A long-lived multi-turn process reaches the same latency, and was rejected:
/// its cost climbed $0.0015 -> $0.0050 across six turns as history accumulated,
/// and earlier dictations became context the model could act on. One process
/// per dictation holds latency at a flat $0.0004.
final class ClaudeStandby {

    private static let timeout: TimeInterval = 2.5

    private let process: Process
    private let stdin: FileHandle
    private let reader: LineReader
    private var consumed = false

    /// Throws if the binary will not start.
    init(binary: String, mode: CleanupMode, vocabulary: [String]) throws {
        // Run somewhere inert: the child inherits our working directory, and a
        // directory containing a CLAUDE.md would otherwise be discovered and
        // prepended to every correction.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.currentDirectoryURL = scratch
        process.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--model", "claude-haiku-4-5-20251001",
            "--tools", "",
            // A public repo runs on machines whose config we do not control.
            // These three stop a stranger's CLAUDE.md, plugins, hooks and MCP
            // servers from slowing down or contaminating the correction, and
            // stop every dictation being written to disk as a session.
            "--safe-mode",
            "--strict-mcp-config",
            "--no-session-persistence",
            "--system-prompt", CleanupPrompt.system(mode: mode, vocabulary: vocabulary),
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["MAX_THINKING_TOKENS"] = "0"
        process.environment = environment

        let inPipe = Pipe(), outPipe = Pipe()
        // A pre-warmed CLI can quit before the transcript is sent. Suppress
        // SIGPIPE on this descriptor so a closed input becomes a caught error.
        let inputFD = inPipe.fileHandleForWriting.fileDescriptor
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0 else {
            throw CleanupError.unavailable("could not configure cleanup input")
        }
        // Never block dictation on a child which has stopped reading stdin.
        let flags = fcntl(inputFD, F_GETFL)
        guard flags >= 0, fcntl(inputFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw CleanupError.unavailable("could not configure nonblocking cleanup input")
        }
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CleanupError.unavailable("could not start \(binary): \(error)")
        }

        stdin = inPipe.fileHandleForWriting
        reader = LineReader(handle: outPipe.fileHandleForReading)
    }

    /// Sends the transcript and returns the correction. Single use.
    func correct(_ transcript: String) async throws -> String {
        guard !consumed else { throw CleanupError.unavailable("standby already used") }
        consumed = true
        defer { discard() }

        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": transcript]]],
        ]
        guard var payload = try? JSONSerialization.data(withJSONObject: message) else {
            throw CleanupError.badResponse("could not encode request")
        }
        payload.append(0x0A)

        do {
            try payload.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(stdin.fileDescriptor,
                                               bytes.baseAddress!.advanced(by: offset),
                                               bytes.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        throw CleanupError.unavailable("cleanup input is not writable")
                    }
                }
            }
            try stdin.close()
        } catch {
            throw CleanupError.unavailable("write failed: \(error)")
        }

        return try await withThrowingTaskGroup(of: String.self) { group in
            defer { group.cancelAll() }
            group.addTask { [reader, process] in
                let result = try await Self.readResult(from: reader)
                // Even a success-shaped frame is unusable if the CLI then fails.
                // Polling stays cancellable within the same 2.5-second budget.
                while process.isRunning {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    throw CleanupError.badResponse("CLI exited unsuccessfully")
                }
                return result
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
                throw CleanupError.timedOut
            }
            guard let first = try await group.next() else {
                throw CleanupError.badResponse("no result")
            }
            return first
        }
    }

    func discard() {
        reader.stop()
        if process.isRunning { process.terminate() }
    }

    /// Reads stream-json frames until the terminal `{"type":"result"}`.
    private static func readResult(from reader: LineReader) async throws -> String {
        while let line = try await reader.nextLine() {
            guard let data = line.data(using: .utf8),
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if frame["type"] as? String == "error" || frame["is_error"] as? Bool == true {
                throw CleanupError.badResponse("CLI reported an error")
            }
            guard frame["type"] as? String == "result" else { continue }
            guard frame["subtype"] as? String == "success",
                  frame["is_error"] as? Bool == false,
                  frame["error"] == nil,
                  frame["errors"] == nil || (frame["errors"] as? [Any])?.isEmpty == true else {
                throw CleanupError.badResponse("result was not an explicit success")
            }
            guard let result = frame["result"] as? String else {
                throw CleanupError.badResponse("result frame carried no text")
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw CleanupError.badResponse("stream ended before a result")
    }
}
