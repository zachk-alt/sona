import Foundation

/// Finds AI CLI binaries from inside a GUI-launched app.
///
/// A .app launched by Finder, the Dock, or a login item inherits
/// PATH=/usr/bin:/bin:/usr/sbin:/sbin. Every common install location for
/// `claude` (~/.local/bin, /opt/homebrew/bin, /usr/local/bin) is missing from
/// it, so a bare `claude` lookup fails in the shipped app while working fine
/// from a terminal. Resolve the absolute path explicitly instead.
enum CLIResolver {

    /// Locations to probe before paying for a login shell, in priority order.
    private static func candidatePaths(for tool: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/\(tool)",
            "\(home)/.claude/local/\(tool)",
            "/opt/homebrew/bin/\(tool)",
            "/usr/local/bin/\(tool)",
            "\(home)/.bun/bin/\(tool)",
            "\(home)/.volta/bin/\(tool)",
            "/usr/bin/\(tool)",
        ]
    }

    /// Absolute path to `tool`, or nil if it cannot be found.
    ///
    /// - Parameter override: an explicit path from user config, tried first.
    static func resolve(_ tool: String, override: String? = nil) -> String? {
        if let override, isExecutable(override) { return override }

        for path in candidatePaths(for: tool) where isExecutable(path) {
            return path
        }

        // Last resort: ask a login shell, which sources the user's dotfiles and
        // therefore knows about version managers we cannot enumerate.
        return askLoginShell(for: tool)
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// ~100ms, so this is the fallback rather than the first move.
    private static func askLoginShell(for tool: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v \(tool)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return isExecutable(path) ? path : nil
    }
}
