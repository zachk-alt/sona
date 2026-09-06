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

    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Murmur.log")
    private static let queue = DispatchQueue(label: "murmur.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

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
