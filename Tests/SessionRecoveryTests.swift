import AppKit
import AVFoundation

// Real AppState sessions driven through its hotkey handler, with a fake speech
// engine, microphone and cues. Compiled with every app source except main.swift
// (scripts/test-session-recovery.sh). Never opens the microphone, plays a sound
// or calls an AI provider; fake transcripts are empty, so nothing is inserted.
// The menu bar icon and the recording panel do appear while it runs.

final class FakeCapture: AudioCapturing {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onSpectrum: (([Float]) -> Void)?
    var failNextStart = false
    private(set) var starts = 0
    func start(convertingTo format: AVAudioFormat?) throws {
        if failNextStart {
            failNextStart = false
            throw FrameworkException(name: "com.apple.coreaudio.avfaudio", reason: "Failed to create tap due to format mismatch")
        }
        starts += 1
    }
    func stop() {}
}

final class SilentCue: CuePlaying {
    func prepare(choice: String?, startFile: String?, stopFile: String?, reverbMix: Double) {}
    func setSound(_ id: String) {}
    func start() {}
    func stop() {}
}

/// A speech engine that can stall at one stage until released.
final class FakeTranscriber: Transcriber, @unchecked Sendable {
    enum Stall { case none, begin, finish, cancel }
    struct BeginFailure: Error {}
    let stall: Stall
    /// What finish() returns. Non-empty only where a test checks retention:
    /// a current session would insert it into the focused field.
    let text: String
    let failBegin: Bool
    private let lock = NSLock()
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var began = 0, finished = 0, cancelled = 0
    init(_ stall: Stall = .none, text: String = "", failBegin: Bool = false) {
        self.stall = stall; self.text = text; self.failBegin = failBegin
    }

    var beginCount: Int { lock.withLock { began } }
    var finishCount: Int { lock.withLock { finished } }
    var cancelCount: Int { lock.withLock { cancelled } }
    var requiredFormat: AVAudioFormat? {
        get async { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) }
    }
    func prepare() async {}
    func begin() async throws {
        lock.withLock { began += 1 }
        if stall == .begin { await park() }
        if failBegin { throw BeginFailure() }
    }
    func feed(_ buffer: AVAudioPCMBuffer) {}
    func finish() async throws -> String {
        lock.withLock { finished += 1 }
        if stall == .finish { await park() }
        return text
    }
    func cancel() async {
        lock.withLock { cancelled += 1 }
        if stall == .cancel { await park() }
    }
    /// Lets a stalled stage finish late, as a stuck analyzer sometimes does.
    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { parked.removeAll() }
            return parked
        }
        waiting.forEach { $0.resume() }
    }
    private func park() async {
        await withCheckedContinuation { continuation in lock.withLock { parked.append(continuation) } }
    }
}

@MainActor
final class SessionRecoveryTests: NSObject, NSApplicationDelegate {
    var checks = 0
    func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { print("FAILED: \(message)"); exit(1) }
    }
    func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
    /// Polls instead of sleeping a fixed time, so a slow machine cannot flake.
    func eventually(_ timeout: Double = 4, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            await wait(0.02)
        }
        return condition()
    }

    static var config: Config {
        var config = Config()
        config.setupComplete = true
        config.requireTextField = false
        config.cleanupEnabled = false
        config.autoAddToDictionary = false
        config.ai.provider = "none"
        return config
    }
    static func deadlines(_ seconds: TimeInterval) -> AppState.Deadlines {
        var d = AppState.Deadlines(bridgeTimeout: 1)
        d.opening = seconds; d.transcribing = seconds; d.finishing = seconds; d.cancelling = seconds
        return d
    }

    /// Engines handed out in order, one per AppState transcriber slot.
    func makeState(_ engines: [FakeTranscriber], capture: FakeCapture = FakeCapture(),
                   deadline: TimeInterval = 1.0) -> AppState {
        var queue = engines
        return AppState(config: Self.config,
                        makeTranscriber: { queue.isEmpty ? FakeTranscriber() : queue.removeFirst() },
                        capture: capture, cue: SilentCue(), deadlines: Self.deadlines(deadline))
    }

    /// Presses the hotkey, holds it until the mic is open, releases.
    func dictate(_ state: AppState) async -> Bool {
        guard state.handle(.begin) else { return false }
        _ = await eventually { state.testingPhase == "recording" }
        await wait(0.05)
        _ = state.handle(.commit)
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await run(); print("Session recovery: \(checks) checks passed; fake speech engine, no microphone, sound or AI."); exit(0) }
    }

    func run() async {
        // A healthy dictation returns to ready and the next press is accepted.
        do {
            let engine = FakeTranscriber()
            let state = makeState([engine])
            check(await dictate(state), "A press from ready is accepted")
            check(await eventually { state.testingPhase == "idle" }, "A normal dictation returns to ready")
            check(engine.beginCount == 1 && engine.finishCount == 1, "The normal path opens and finishes the analyzer once")
        }

        // Without a deadline, a stalled analyzer strands the session: the
        // state that used to need a quit and reopen.
        do {
            let stuck = FakeTranscriber(.finish)
            let state = makeState([stuck], deadline: 1000)
            _ = await dictate(state)
            await wait(1.5)
            check(state.testingPhase == "processing", "Control: a stalled finish holds the session with no deadline")
            check(!state.handle(.begin), "Control: and every later press is refused")
            stuck.release()
            await wait(0.2)
        }

        // Stalled transcription: the deadline resets, the next session uses a
        // fresh engine, and the late result cannot disturb a newer session.
        do {
            let stuck = FakeTranscriber(.finish), fresh = FakeTranscriber(), third = FakeTranscriber()
            let state = makeState([stuck, fresh, third])
            _ = await dictate(state)
            await wait(0.2)
            check(state.testingPhase == "processing", "A stalled finish is still processing before its deadline")
            check(await eventually { state.testingPhase == "idle" }, "The transcription deadline returns the app to ready")
            check(await dictate(state), "The press after a stall is accepted")
            check(await eventually { state.testingPhase == "idle" } && fresh.beginCount == 1 && fresh.finishCount == 1,
                  "The session after a stall runs on a fresh engine")
            check(state.handle(.begin), "A third session starts")
            check(await eventually { state.testingPhase == "recording" }, "The third session is recording")
            stuck.release()
            await wait(0.3)
            check(state.testingPhase == "recording", "A late result from the abandoned session does not end a newer one")
            _ = state.handle(.commit)
            check(await eventually { state.testingPhase == "idle" }, "The newer session still finishes normally")
        }

        // Stalled microphone opening: reset while the key is still held; the
        // release that follows is harmless; the next press works.
        do {
            let stuck = FakeTranscriber(.begin), fresh = FakeTranscriber()
            let capture = FakeCapture()
            let state = makeState([stuck, fresh], capture: capture)
            check(state.handle(.begin), "A press with a stalling analyzer is accepted")
            check(await eventually { state.testingPhase == "recording" }, "The session waits on the stalled opening")
            check(await eventually { state.testingPhase == "idle" }, "The opening deadline returns the app to ready")
            check(state.testingLastMessage == "Dictation didn't start in time. Try again.",
                  "The opening deadline says dictation did not start, without blaming the microphone")
            _ = state.handle(.commit)
            await wait(0.1)
            check(state.testingPhase == "idle", "Releasing the key after the reset changes nothing")
            check(await dictate(state), "The press after a stalled opening is accepted")
            check(await eventually { state.testingPhase == "idle" } && fresh.finishCount == 1, "And it completes on a fresh engine")
            let startsBefore = capture.starts
            stuck.release()
            await wait(0.3)
            check(state.testingPhase == "idle" && capture.starts == startsBefore, "The late opening never starts the microphone")
            check(stuck.cancelCount == 1, "The late opening releases its abandoned analyzer")
        }

        // Stalled cancel after a discarded gesture.
        do {
            let stuck = FakeTranscriber(.cancel), fresh = FakeTranscriber()
            let state = makeState([stuck, fresh])
            check(state.handle(.begin), "Press accepted")
            _ = await eventually { state.testingPhase == "recording" }
            _ = state.handle(.discard)
            await wait(0.2)
            check(state.testingPhase == "cancelling", "A stalled cancel holds before its deadline")
            check(await eventually { state.testingPhase == "idle" }, "The cancel deadline returns the app to ready")
            check(await dictate(state), "The press after a stalled cancel is accepted")
            check(await eventually { state.testingPhase == "idle" }, "And it completes")
            stuck.release()
        }

        // A speech engine that fails to start is not blamed on the microphone.
        do {
            let state = makeState([FakeTranscriber(failBegin: true), FakeTranscriber()])
            check(state.handle(.begin), "Press accepted with a failing speech engine")
            check(await eventually { state.testingPhase == "idle" }, "A failing speech engine returns the app to ready")
            check(state.testingLastMessage == "Speech recognition couldn't start. Try again in a moment.",
                  "A speech engine failure names speech recognition")
            _ = state.handle(.commit)
            check(await dictate(state), "The next press is accepted")
            check(await eventually { state.testingPhase == "idle" }, "And it completes")
        }

        // Words that arrive after their session was abandoned are kept in Copy
        // pending text, never pasted, and never disturb a newer session.
        do {
            let late = FakeTranscriber(.finish, text: "late words"), fresh = FakeTranscriber()
            let state = makeState([late, fresh])
            _ = await dictate(state)
            check(await eventually { state.testingPhase == "idle" }, "The stalled transcription is abandoned")
            check(state.handle(.begin), "A newer session starts")
            check(await eventually { state.testingPhase == "recording" }, "The newer session is recording")
            let pendingBefore = TextInserter.pendingCount
            late.release()
            check(await eventually { TextInserter.pendingCount == pendingBefore + 1 }, "Late words are kept in Copy pending text")
            check(state.testingPhase == "recording", "Keeping them does not disturb the newer session")
            _ = state.handle(.commit)
            check(await eventually { state.testingPhase == "idle" }, "The newer session still finishes")
            check(TextInserter.pendingCount == pendingBefore + 1, "Nothing else was kept or pasted")
        }

        // A busy microphone (the AVFAudio raise, now a thrown error) ends the
        // session cleanly and the next press opens the mic.
        do {
            let capture = FakeCapture()
            capture.failNextStart = true
            let state = makeState([FakeTranscriber(), FakeTranscriber()], capture: capture)
            check(state.handle(.begin), "Press accepted with a busy microphone")
            check(await eventually { state.testingPhase == "idle" }, "A busy microphone returns the app to ready at once")
            check(state.testingLastMessage == "The microphone is unavailable or switching. Try again.", "A busy microphone says so")
            _ = state.handle(.commit)
            check(await dictate(state), "The next press is accepted")
            check(await eventually { state.testingPhase == "idle" } && capture.starts == 1, "And it opens the microphone and completes")
        }
    }
}

@main
struct SessionRecoveryMain {
    static func main() {
        let app = NSApplication.shared
        let tests = MainActor.assumeIsolated { SessionRecoveryTests() }
        app.delegate = tests
        app.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { print("FAILED: timed out"); exit(1) }
        app.run()
    }
}
