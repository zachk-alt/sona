import AppKit

// SonaApplication and MainQueueRecovery against real unwrapped Objective-C
// exceptions (scripts/test-exception-recovery.sh). Each scenario runs in a
// child copy of this program, because two of them end the process. Nothing
// appears on screen. The relaunch itself is never started: this program is not
// an app bundle, so MainQueueRecovery declines and says so in its log.

enum Scenario: String, CaseIterable {
    /// Raised in a main-actor task: AppKit swallows it and the main queue
    /// wedges. Recovery must detect the wedge.
    case task
    /// Raised in a run-loop timer: AppKit swallows it, nothing wedges.
    /// Recovery must not act.
    case timer
    /// Raised in a plain main-queue block: the process aborts. The chained
    /// handler must run before it does.
    case queue
}

/// Child mode: one scenario, reported on stdout.
func runScenario(_ scenario: Scenario) -> Never {
    setvbuf(stdout, nil, _IONBF, 0)
    // The abort in the queue scenario is expected: exit quietly instead of
    // leaving a crash report or a "quit unexpectedly" dialog.
    signal(SIGABRT) { _ in _exit(134) }
    let app = SonaApplication.shared
    MainQueueRecovery.installUncaughtHandler()
    MainQueueRecovery.onDeadMainQueue = {
        print("RECOVERY: main queue confirmed dead")
        exit(0)
    }
    func raise() { NSException(name: .genericException, reason: "test", userInfo: nil).raise() }
    final class Delegate: NSObject, NSApplicationDelegate {
        let scenario: Scenario
        let raise: () -> Void
        init(_ scenario: Scenario, _ raise: @escaping () -> Void) { self.scenario = scenario; self.raise = raise }
        func applicationDidFinishLaunching(_ notification: Notification) {
            switch scenario {
            case .task:
                Task { @MainActor in raise() }
            case .timer:
                RunLoop.main.add(Timer(timeInterval: 0.1, repeats: false) { _ in self.raise() }, forMode: .common)
                // A healthy app keeps running main-queue work; report after the probe window.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { print("ALIVE: main queue still running"); exit(0) }
            case .queue:
                DispatchQueue.main.async { self.raise() }
            }
        }
    }
    let delegate = Delegate(scenario, raise)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    DispatchQueue.global().asyncAfter(deadline: .now() + 12) { print("TIMEOUT"); exit(3) }
    app.run()
    exit(4)
}

@main
struct ExceptionRecoveryTests {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--scenario", let scenario = Scenario(rawValue: arguments[2]) {
            runScenario(scenario)
        }
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("sona-tests.log")
        try? FileManager.default.removeItem(at: logURL)
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { print("FAILED: \(message)"); exit(1) }
        }
        func child(_ scenario: Scenario) -> (status: Int32, output: String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: arguments[0])
            process.arguments = ["--scenario", scenario.rawValue]
            process.standardOutput = pipe
            process.standardError = pipe
            try! process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        let task = child(.task)
        check(task.status == 0 && task.output.contains("RECOVERY: main queue confirmed dead"),
              "An exception in a main-actor task is detected as a dead main queue (exit \(task.status))")

        let timer = child(.timer)
        check(timer.status == 0 && timer.output.contains("ALIVE") && !timer.output.contains("RECOVERY"),
              "An exception that leaves the main queue alive does not trigger recovery (exit \(timer.status))")

        let queue = child(.queue)
        check(queue.status != 0 && queue.output.contains("NSGenericException"),
              "An exception in a main-queue block still ends the process (exit \(queue.status))")
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        check(log.contains("exception: uncaught NSGenericException; Sona is ending"),
              "The chained handler runs before the process ends")
        check(log.contains("exception: not running from an app bundle; not relaunching"),
              "And it attempts the relaunch (declined here: not an app bundle)")

        print("Exception recovery: \(checks) checks passed; real raises in child processes, nothing on screen, no relaunch.")
    }
}
