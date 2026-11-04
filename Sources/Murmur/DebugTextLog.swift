import Foundation

/// Opt-in developer log of dictation text, for accuracy review. Off unless the
/// private config holds "debugTextLog": {"until": "<ISO-8601>"} with a time in
/// the future. While on, each dictation appends one JSON line to
/// ~/Library/Logs/Sona/debug-text/YYYY-MM-DD.jsonl; files older than seven
/// days are pruned at launch and before each write. Once `until` has passed,
/// every file in the folder is deleted (at launch and at the next dictation)
/// and nothing is written. No timer or background job: work happens only when
/// the app calls `housekeep()` or `record(...)`.
///
/// This folder is separate from the normal log on purpose. Log.write, Doctor,
/// diagnostics and exports never read it.
struct DebugTextLog {
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    static var defaultFolder: URL {
        #if SESSION_RECOVERY_TESTS || SONA_TEST_LOG
        // Test builds run real sessions: never read, write or purge the
        // user's real debug log.
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("sona-tests-debug-text", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Sona/debug-text", isDirectory: true)
        #endif
    }

    /// The config file the setting is read from at each dictation.
    static var defaultConfigURL: URL {
        #if SESSION_RECOVERY_TESTS || SONA_TEST_LOG
        // Absent in test builds, so the log reads as off.
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("sona-tests-debug-text-config.json")
        #else
        return Config.configURL
        #endif
    }

    let folder: URL
    let until: Date?
    let now: () -> Date

    init(until: Date?, folder: URL = DebugTextLog.defaultFolder, now: @escaping () -> Date = Date.init) {
        self.until = until
        self.folder = folder
        self.now = now
    }

    /// Reads the setting fresh from the private config file, so a hand edit
    /// that removes or ends `debugTextLog` takes effect at the next dictation
    /// with Sona still running. The in-memory config is loaded once at launch
    /// and never reloads. A missing or malformed file reads as off.
    static func fromConfigFile(_ url: URL = DebugTextLog.defaultConfigURL, folder: URL = DebugTextLog.defaultFolder,
                               now: @escaping () -> Date = Date.init) -> DebugTextLog {
        DebugTextLog(until: Config.load(from: url).debugTextLogUntil, folder: folder, now: now)
    }

    var isOn: Bool {
        guard let until else { return false }
        return now() < until
    }

    /// At launch and before each write: prune old files while on; delete
    /// every file once the window has ended or the setting was removed.
    /// Creates nothing, so a user who never enabled it gets no folder.
    func housekeep() {
        if isOn { prune() } else { purgeAll() }
    }

    /// One dictation. Writes only while on.
    func record(engineText: String, cleanedText: String?, cleanupStatus: String, reason: String?) {
        housekeep()
        guard isOn, ensureFolder() else { return }
        let object: [String: Any] = [
            "time": Self.timestamp(now()),
            "engineText": engineText,
            "cleanedText": cleanedText.map { $0 as Any } ?? NSNull(),
            "cleanupStatus": cleanupStatus,
            "reason": reason.map { $0 as Any } ?? NSNull(),
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        append(line, to: fileURL(for: now()))
    }

    func fileURL(for date: Date) -> URL {
        folder.appendingPathComponent(Self.dayFormatter.string(from: date) + ".jsonl")
    }

    // MARK: - Files

    /// Creates the folder with mode 0700 at creation. An existing folder is
    /// used only when it is a real directory, not a link.
    private func ensureFolder() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(folder.path, 0o700) == 0 { return true }
        guard errno == EEXIST,
              let attrs = try? fm.attributesOfItem(atPath: folder.path),
              attrs[.type] as? FileAttributeType == .typeDirectory else { return false }
        return true
    }

    /// Opens with mode 0600 at creation (O_CREAT), never chmod afterwards,
    /// and refuses to follow a link.
    private func append(_ data: Data, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = write(fd, base, left)
                if n <= 0 { return }
                left -= n; base = base.advanced(by: n)
            }
        }
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    /// Deletes day files whose day began more than seven days ago. A file
    /// name Sona did not write is treated as old.
    func prune() {
        let cutoff = now().addingTimeInterval(-Self.retention)
        for file in files() {
            let name = file.deletingPathExtension().lastPathComponent
            if let day = Self.dayFormatter.date(from: name), file.pathExtension == "jsonl", day >= cutoff { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    func purgeAll() {
        for file in files() { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: - Formats

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
