import Foundation

/// Append-only log at ~/Library/Logs/Murmur.log.
///
/// A menu bar app with no window has no way to tell you why it is doing
/// nothing, and the failure that matters here (an event tap that is created
/// successfully and then never delivers an event) is completely silent. This
/// exists so that "the key does nothing" is a diagnosable statement.
///
/// Transcript text is never written, only its length.
enum Log {

    private static let url: URL = {
        #if SESSION_RECOVERY_TESTS || SONA_TEST_LOG
        // Test builds never write into the real app's diagnostics.
        return FileManager.default.temporaryDirectory.appendingPathComponent("sona-tests.log")
        #else
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Murmur.log")
        #endif
    }()
    private static let queue = DispatchQueue(label: "murmur.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// The log appends across launches, so the session that ended in a quit
    /// and reopen is still readable afterwards. Each launch starts with a
    /// dated line (the per-line stamps carry only the time of day), and a log
    /// past `rotationBytes` moves to Murmur.previous.log first.
    static func beginLaunch() {
        let rotationBytes = 2_000_000
        queue.sync {
            let manager = FileManager.default
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > rotationBytes {
                let previous = url.deletingLastPathComponent().appendingPathComponent("Murmur.previous.log")
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: url, to: previous)
            }
        }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime])
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        write("==== launch \(stamp) pid \(ProcessInfo.processInfo.processIdentifier) version \(version) ====")
    }

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.sync {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
