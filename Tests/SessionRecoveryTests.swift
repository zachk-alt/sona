import AppKit
import AVFoundation

// Real AppState sessions driven through its hotkey handler, with a fake speech
// engine, microphone and cues. Compiled with every app source except main.swift
// (scripts/test-session-recovery.sh). Never opens the microphone, plays a sound
// or calls an AI provider; fake transcripts are empty, so nothing is inserted.
// The menu bar icon and the recording panel do appear while it runs.

/// What happened, in order, across the fake microphone and cues.
final class EventOrder {
    private(set) var events: [String] = []
    func note(_ event: String) { events.append(event) }
}

final class FakeCapture: AudioCapturing {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onSpectrum: (([Float]) -> Void)?
    var failNextStart = false
    let order: EventOrder?
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var running = false
    /// Uptime of the last start and stop.
    private(set) var startedAt = 0.0, stoppedAt = 0.0
    init(order: EventOrder? = nil) { self.order = order }
    func start(convertingTo format: AVAudioFormat?) throws {
        if failNextStart {
            failNextStart = false
            throw FrameworkException(name: "com.apple.coreaudio.avfaudio", reason: "Failed to create tap due to format mismatch")
        }
        starts += 1
        running = true
        startedAt = ProcessInfo.processInfo.systemUptime
        order?.note("mic open")
    }
    func stop() {
        guard running else { return }
        running = false
        stops += 1
        stoppedAt = ProcessInfo.processInfo.systemUptime
        order?.note("mic closed")
    }
    /// One 100 ms buffer of quiet tone, delivered off the main thread like the tap.
    func deliver() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for i in 0..<1600 { buffer.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.2) }
        let callback = onBuffer
        DispatchQueue.global().async { callback?(buffer) }
    }
}

final class SilentCue: CuePlaying {
    let order: EventOrder?
    private(set) var starts = 0, stops = 0
    init(order: EventOrder? = nil) { self.order = order }
    func prepare(choice: String?, startFile: String?, stopFile: String?, reverbMix: Double) {}
    func setSound(_ id: String) {}
    func start() { starts += 1; order?.note("start chime") }
    func stop() { stops += 1; order?.note("stop chime") }
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
                   cue: SilentCue = SilentCue(), deadline: TimeInterval = 1.0,
                   firstAudio: TimeInterval = 1.5) -> AppState {
        var queue = engines
        var deadlines = Self.deadlines(deadline)
        deadlines.firstAudio = firstAudio
        return AppState(config: Self.config,
                        makeTranscriber: { queue.isEmpty ? FakeTranscriber() : queue.removeFirst() },
                        capture: capture, cue: cue, deadlines: deadlines)
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
        await startTiming()
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

extension SessionRecoveryTests {
    /// Start and stop timing: the mic delay runs from the physical press, the
    /// chime and panel wait for the first audio, and the stop keeps listening
    /// briefly before the mic closes and the stop chime plays.
    func startTiming() async {
        // The chime means the microphone is live.
        do {
            let order = EventOrder()
            let capture = FakeCapture(order: order), cue = SilentCue(order: order)
            let state = makeState([FakeTranscriber()], capture: capture, cue: cue)
            check(state.handle(.begin), "A press is accepted")
            check(await eventually { capture.starts == 1 }, "The microphone opens after the delay")
            await wait(0.15)
            check(cue.starts == 0 && !state.testingRecordingShown, "No chime and no recording panel before the first audio")
            capture.deliver()
            check(await eventually { cue.starts == 1 && state.testingRecordingShown }, "The first audio plays the chime and shows recording")
            capture.deliver(); capture.deliver()
            await wait(0.1)
            check(cue.starts == 1, "Later audio does not replay the chime")
            let released = ProcessInfo.processInfo.systemUptime
            _ = state.handle(.commit)
            check(await eventually { state.testingPhase == "idle" }, "The dictation finishes")
            let grace = capture.stoppedAt - released
            check(grace >= 0.1 && grace < 0.5, "The mic keeps listening about 120 ms after the stop (\(Int(grace * 1000)) ms)")
            check(order.events == ["mic open", "start chime", "mic closed", "stop chime"],
                  "The start chime follows audio and the stop chime follows the mic closing: \(order.events)")
        }

        // A microphone that sends nothing: the panel still shows, the chime never lies.
        do {
            let capture = FakeCapture(), cue = SilentCue()
            let state = makeState([FakeTranscriber()], capture: capture, cue: cue, firstAudio: 0.3)
            check(state.handle(.begin), "A press with a silent microphone is accepted")
            check(await eventually { capture.starts == 1 }, "Its microphone opens")
            check(!state.testingRecordingShown, "Recording is not shown at once")
            check(await eventually { state.testingRecordingShown }, "The first-audio deadline shows recording anyway")
            check(cue.starts == 0, "No start chime plays without audio")
            _ = state.handle(.commit)
            check(await eventually { state.testingPhase == "idle" }, "A session that heard nothing still returns to ready")
            check(cue.stops == 0, "No stop chime plays for a session whose start chime never played")
            check(capture.stops == 1, "Its microphone is closed")
        }

        // Audio that arrives late, after the fallback, still plays the chime once.
        do {
            let capture = FakeCapture(), cue = SilentCue()
            let state = makeState([FakeTranscriber()], capture: capture, cue: cue, firstAudio: 0.2)
            _ = state.handle(.begin)
            check(await eventually { state.testingRecordingShown }, "The fallback shows recording")
            capture.deliver()
            check(await eventually { cue.starts == 1 }, "Late first audio still plays the chime once")
            _ = state.handle(.commit)
            check(await eventually { state.testingPhase == "idle" } && cue.stops == 1, "And the stop chime plays")
        }

        // The 150 ms mic delay counts from the physical press, not from when
        // the main thread handled it, so focus checks run inside it.
        do {
            let capture = FakeCapture()
            let state = makeState([FakeTranscriber()], capture: capture)
            let pressed = ProcessInfo.processInfo.systemUptime
            _ = state.handle(.begin, timing: HotKeyTiming(pressedAt: pressed))
            await wait(0.08)
            check(capture.starts == 0, "The microphone does not open before the delay")
            check(await eventually { capture.starts == 1 }, "It opens after the delay")
            let delay = capture.startedAt - pressed
            check(delay >= 0.14, "A fresh press waits the full 150 ms (\(Int(delay * 1000)) ms)")
            _ = state.handle(.discard)
            check(await eventually { state.testingPhase == "idle" }, "Discard returns to ready")

            // A press the main thread saw 150 ms late opens at once.
            let early = ProcessInfo.processInfo.systemUptime - 0.15
            _ = state.handle(.begin, timing: HotKeyTiming(pressedAt: early))
            check(await eventually(0.12) { capture.starts == 2 }, "A press handled late does not wait another 150 ms")
            _ = state.handle(.discard)
            check(await eventually { state.testingPhase == "idle" }, "Discard returns to ready")
        }

        // A tap shorter than the delay opens nothing and plays nothing.
        do {
            let capture = FakeCapture(), cue = SilentCue()
            let state = makeState([FakeTranscriber()], capture: capture, cue: cue)
            _ = state.handle(.begin)
            _ = state.handle(.commit)
            await wait(0.3)
            check(capture.starts == 0 && cue.starts == 0 && cue.stops == 0 && state.testingPhase == "idle",
                  "A press released inside the delay opens no microphone and plays no chime")
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
