import Foundation

@main
struct SwiftBridgeTests {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { fatalError("node path and fixture path required") }
        let nodePath = arguments[1], bridgePath = arguments[2]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sona-swift-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The same argv shape the app uses: bridge script, config path and mode only.
        // The transcript travels on stdin; the fixture exits 2 if it appears in argv.
        func run(_ scenario: String, _ input: String, mode: String = "prose", node: String? = nil) throws -> CleanupBridgeRun {
            let config = directory.appendingPathComponent("\(scenario).json")
            try JSONSerialization.data(withJSONObject: ["scenario": scenario]).write(to: config)
            return CleanupBridgeRun(nodePath: node ?? nodePath, arguments: [bridgePath, "--config", config.path,
                "--mode", mode], input: input, timeout: 1)
        }
        func perform(_ run: CleanupBridgeRun) async -> String {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: run.perform()) }
            }
        }
        let raw = "um hello world"
        let cleaned = await perform(try run("success", raw))
        precondition(cleaned == "Hello, world.")
        for scenario in ["early-close", "empty", "nonzero", "overflow", "hang", "result-then-hang", "never-read"] {
            let start = ProcessInfo.processInfo.systemUptime
            let original = scenario == "never-read" ? String(repeating: "a", count: 63 * 1024) : raw
            let result = await perform(try run(scenario, original, mode: "strict"))
            precondition(result == original, "Failure did not preserve raw text: \(scenario)")
            precondition(ProcessInfo.processInfo.systemUptime - start < 2, "Unbounded: \(scenario)")
        }
        let missingResult = await perform(try run("success", raw, node: "/missing/sona-node"))
        precondition(missingResult == raw)
        let cancelled = try run("hang", raw)
        let cancelStart = ProcessInfo.processInfo.systemUptime
        let task = Task { await perform(cancelled) }
        try await Task.sleep(nanoseconds: 50_000_000)
        cancelled.cancel()
        let cancelledResult = await task.value
        precondition(cancelledResult == raw)
        precondition(ProcessInfo.processInfo.systemUptime - cancelStart < 0.9, "Cancel waited for the deadline")
        let early = try run("success", raw)
        early.cancel()
        let earlyResult = await perform(early)
        precondition(earlyResult == raw, "A run cancelled before it starts must not launch")
        print("PASS: 11 exact-source Swift bridge lifecycle cases, no real models or UI")
    }
}
