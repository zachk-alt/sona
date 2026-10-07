import AppKit
import Foundation

/// The last line of defense against an exception nobody wrapped.
///
/// An Objective-C exception that escapes a framework call ends one of two ways:
/// - Raised in a Swift concurrency job on the main actor (a dictation session
///   task), AppKit catches it in its run loop and keeps the process alive, but
///   the main dispatch queue never runs again: the menu still opens while every
///   key press goes nowhere. That is the state that used to need a manual quit
///   and reopen. `verify()` detects it and relaunches Sona.
/// - Raised in a plain main-queue block or a notification observer, AppKit's
///   uncaught-exception handler reports it and the process aborts. The handler
///   chained in by `installUncaughtHandler()` schedules a relaunch first.
/// Known raisers are wrapped where they are called (see FrameworkException.swift).
final class SonaApplication: NSApplication {
    override func reportException(_ exception: NSException) {
        // Names only, plus AVFAudio's format diagnostics: other exception
        // reasons can quote application text, which the log never holds.
        let name = exception.name.rawValue
        let detail = name.hasPrefix("com.apple.coreaudio") ? ": \((exception.reason ?? "").prefix(200))" : ""
        Log.write("exception: \(name)\(detail)")
        super.reportException(exception)
        MainQueueRecovery.verify()
    }
}

enum MainQueueRecovery {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var checking = false
    nonisolated(unsafe) private static var terminating = false
    nonisolated(unsafe) private static var appKitHandler: (@convention(c) (NSException) -> Void)?
    /// What to do once the main queue is confirmed dead. Tests replace it.
    nonisolated(unsafe) static var onDeadMainQueue: () -> Void = relaunchAndExit
    /// One automatic relaunch per window. A fault that returns right after
    /// a relaunch quits instead, rather than restarting in a loop.
    private static let relaunchWindow: TimeInterval = 120
    /// A wedged main queue still lets the run loop turn. A main thread that is
    /// merely busy answers neither probe; it gets this long before it counts.
    private static let busyLimit: TimeInterval = 30
    private static var marker: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sona/last-recovery-relaunch")
    }

    /// Chains a handler in front of AppKit's for exceptions that will abort the
    /// process. Call after SonaApplication.shared (AppKit installs its own
    /// handler there and would replace an earlier one) and before run().
    static func installUncaughtHandler() {
        appKitHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in MainQueueRecovery.uncaught(exception) }
    }

    private static func uncaught(_ exception: NSException) {
        lock.withLock { terminating = true }
        Log.write("exception: uncaught \(exception.name.rawValue); Sona is ending")
        if spawnRelaunch() { Log.write("exception: relaunch scheduled") }
        // AppKit's handler reports the exception; the runtime then aborts.
        appKitHandler?(exception)
    }

    /// Thread-safe answers from the two probes.
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var queueAnswered = false, runLoopAnswered = false, done = false
        func markQueue() { lock.withLock { queueAnswered = true } }
        func markRunLoop() { lock.withLock { runLoopAnswered = true } }
        func finish() { lock.withLock { done = true } }
        var isDone: Bool { lock.withLock { done } }
        var answers: (queue: Bool, runLoop: Bool) { lock.withLock { (queueAnswered, runLoopAnswered) } }
    }

    /// Called on the main thread right after AppKit swallowed an exception.
    static func verify() {
        let first = lock.withLock { () -> Bool in
            if checking || terminating { return false }
            checking = true
            return true
        }
        guard first else { return }
        let probe = Probe()
        DispatchQueue.main.async { probe.markQueue() }
        let timer = Timer(timeInterval: 0.2, repeats: true) { timer in
            if probe.isDone { timer.invalidate() } else { probe.markRunLoop() }
        }
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            var alive: Bool?
            while alive == nil {
                Thread.sleep(forTimeInterval: 0.1)
                let answers = probe.answers
                let elapsed = Date().timeIntervalSince(started)
                if answers.queue {
                    alive = true
                } else if answers.runLoop && elapsed >= 3 {
                    alive = false   // the run loop turns but the main queue never runs: wedged
                } else if elapsed >= busyLimit {
                    alive = false   // the main thread has not come back at all
                }
            }
            probe.finish()
            lock.withLock { checking = false }
            if alive == true {
                Log.write("exception: main queue still running, continuing")
            } else {
                onDeadMainQueue()
            }
        }
    }

    /// Starts a detached shell that waits for this process to end, then opens
    /// the bundle again. False when a relaunch is not allowed or not possible.
    @discardableResult
    private static func spawnRelaunch() -> Bool {
        let bundle = Bundle.main.bundleURL
        let manager = FileManager.default
        if let last = (try? manager.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(last) < relaunchWindow {
            Log.write("exception: another fault within \(Int(relaunchWindow)) s of a relaunch; not relaunching")
            return false
        }
        guard bundle.pathExtension == "app" else {
            Log.write("exception: not running from an app bundle; not relaunching")
            return false
        }
        try? manager.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        manager.createFile(atPath: marker.path, contents: Data())
        // Waits up to 10 s for this pid to be gone (after exit or abort), so two
        // event taps never run at once, then opens Sona without activating it.
        let script = "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; exec /usr/bin/open -g \"$0\""
        var pid: pid_t = 0
        let argv = ["/bin/sh", "-c", script, bundle.path, String(getpid())]
        var cArgs = argv.map { strdup($0) } + [nil]
        let status = posix_spawn(&pid, "/bin/sh", nil, nil, &cArgs, environ)
        cArgs.forEach { free($0) }
        if status != 0 { Log.write("exception: relaunch failed to start (\(status))") }
        return status == 0
    }

    /// Runs off the main thread, which may be unusable.
    private static func relaunchAndExit() {
        Log.write("exception: main queue dead; relaunching Sona")
        exit(spawnRelaunch() ? 0 : 1)
    }
}
