import Foundation

@main
struct SwiftBridgeTests {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { fatalError("node path and fixture path required") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sona-swift-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func service(_ scenario: String) throws -> BridgeCleanupService {
            let config = directory.appendingPathComponent("\(scenario).json")
            try JSONSerialization.data(withJSONObject: ["scenario": scenario]).write(to: config)
            return BridgeCleanupService(configPath: config.path, bridgePath: arguments[2], nodePath: arguments[1], timeout: 1)
        }
        let raw = "um hello world"
        let success = try service("success")
        let cleaned = try await success.clean(raw, mode: .prose)
        precondition(cleaned == "Hello, world.")
        for scenario in ["early-close", "empty", "nonzero", "overflow", "hang", "result-then-hang", "never-read"] {
            let start = ProcessInfo.processInfo.systemUptime
            let instance = try service(scenario)
            let original = scenario == "never-read" ? String(repeating: "a", count: 63 * 1024) : raw
            let result = try await instance.clean(original, mode: .strict)
            precondition(result == original, "Failure did not preserve raw text: \(scenario)")
            precondition(ProcessInfo.processInfo.systemUptime - start < 2, "Unbounded: \(scenario)")
        }
        let missing = BridgeCleanupService(configPath: "unused", bridgePath: arguments[2], nodePath: "/missing/sona-node")
        let missingResult = try await missing.clean(raw, mode: .prose)
        precondition(missingResult == raw)
        let cancelled = try service("hang")
        let task = Task { try await cancelled.clean(raw, mode: .prose) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let cancelledResult = try await task.value
        precondition(cancelledResult == raw)
        let shutDown = try service("hang")
        let active = Task { try await shutDown.clean(raw, mode: .prose) }
        try await Task.sleep(nanoseconds: 50_000_000)
        shutDown.shutdown()
        let stoppedResult = try await active.value
        precondition(stoppedResult == raw)
        print("PASS: 11 exact-source Swift bridge lifecycle cases, no real models or UI")
    }
}
