import AppKit
import AVFoundation
import ApplicationServices
import Foundation

/// What a session needs from the start/stop cues. Tests substitute it.
protocol CuePlaying: AnyObject {
    func prepare(choice: String?, startFile: String?, stopFile: String?, reverbMix: Double)
    func setSound(_ id: String)
    func start()
    func stop()
}
extension Cue: CuePlaying {}

/// Wires the hotkey to the microphone, the transcriber, the cleanup pass and
/// the focused text field.
///
/// Every dictation is a numbered session, and every wait a session can get
/// stuck in has a deadline. Apple's speech analyzer or the microphone can
/// stall without ever throwing; before these deadlines a single stall left
/// the phase stuck and every later key press was ignored until Sona was quit
/// and reopened. A stage that overruns is abandoned (its transcriber is
/// replaced, never shared with the next session), the app returns to ready,
/// and late results from the abandoned session are discarded by its number.
@MainActor
final class AppState {

    /// The microphone is opened this long after the key goes down, not
    /// instantly. Right-Command is also an ordinary modifier, so opening on
    /// every press would flash the orange recording indicator every time the
    /// user hits Cmd-C. The start chord plays immediately and takes ~90 ms, so
    /// by the time anyone begins speaking the mic is already live.
    private static let micDelay: TimeInterval = 0.15

    /// Longest each stage may take before the session is abandoned. Normal
    /// dictations finish every stage far inside these.
    struct Deadlines {
        /// Key held to microphone open, including the first-launch speech warmup.
        var opening: TimeInterval = 10
        /// Release to final transcript.
        var transcribing: TimeInterval = 15
        /// Transcript to inserted text: the bounded cleanup bridge plus insertion.
        var finishing: TimeInterval
        /// Discard to released analyzer.
        var cancelling: TimeInterval = 5

        init(bridgeTimeout: TimeInterval) { finishing = bridgeTimeout + 8 }
    }

    private var config: Config
    private let statusBar = StatusBarController()
    private let cue: CuePlaying
    private let capture: AudioCapturing
    private let makeTranscriber: () -> Transcriber
    /// Replaced, not reused, after a stalled session.
    private var transcriber: Transcriber
    private let deadlines: Deadlines
    private var sessionID = 0
    private var watchdog: DispatchWorkItem?
    private var operations: BridgeOperations
    private var textSettings: TextSettingsController?
    private let corrections = CorrectionObservation()
    private var correctionSuggestion: String?
    private var observationBaseline: SelectionSnapshot?
    private var sessionFailure: String?
    private var hotKey: HotKeyMonitor?
    private var hotkeySettings: HotKeySettings?
    private var backendLabel = "Plain dictation"
    private var insertionTarget: FocusedElement.Target?

    private enum Phase { case idle, armed, recording, processing, cancelling }
    private var phase: Phase = .idle
    private var pendingMicStart: DispatchWorkItem?
    private var microphoneStart: Task<Bool, Never>?
    private var warmup: Task<Void, Never>?
    private var sessionMode: CleanupMode = .prose

    init(config: Config = Config.load(),
         makeTranscriber: @escaping () -> Transcriber = { AppleTranscriber() },
         capture: AudioCapturing = AudioCapture(),
         cue: CuePlaying = Cue(),
         deadlines: Deadlines? = nil) {
        self.config = config
        self.makeTranscriber = makeTranscriber
        self.transcriber = makeTranscriber()
        self.capture = capture
        self.cue = cue
        let selected = Self.makeCleanup(config)
        operations = selected.0
        backendLabel = selected.1
        self.deadlines = deadlines ?? Deadlines(bridgeTimeout: selected.2)

        capture.onLevel = { [weak self] level in
            guard let self, phase == .recording else { return }
            statusBar.setLevel(level)
        }
        capture.onSpectrum = { [weak self] bands in
            guard let self, phase == .recording else { return }
            statusBar.setSpectrum(bands)
        }
    }

    private static func makeCleanup(_ config: Config) -> (BridgeOperations, String, TimeInterval) {
        let resources = Bundle.main.resourceURL
        let bridge = resources?.appendingPathComponent("bridge/sona-cleanup.mjs")
            ?? URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("bridge/sona-cleanup.mjs")
        let bundled = resources?.appendingPathComponent("runtime/node").path
        let node = bundled.flatMap { FileManager.default.isExecutableFile(atPath:$0) ? $0 : nil } ?? CLIResolver.resolve("node")
        let label = config.ai.provider == "none" ? "Plain dictation and saved phrases" : "\(config.ai.provider.capitalized), \(config.ai.model)"
        // BridgeOperations clamps the same way; the finishing deadline must outlast it.
        let timeout = min(35, max(1, Double(config.ai.timeoutMs)/1000+2))
        return (BridgeOperations(node:node,bridge:bridge.path,timeout:timeout),label,timeout)
    }

    private func makeMonitor() -> HotKeyMonitor? {
        guard let primary = HotKeyBinding(config.hotkey) else { return nil }
        return HotKeyMonitor(binding:primary) { [weak self] event in
            self?.handle(event) ?? false
        }
    }
    private func resumeHotkeys() {
        statusBar.setHotkey(config.hotkey)
        let monitor = makeMonitor()
        if monitor?.start() == true { hotKey = monitor }
    }
    private func showHotkeySettings() {
        guard phase == .idle, hotkeySettings == nil, textSettings == nil else { NSSound.beep(); return }
        corrections.stop(); hotKey?.stop(); hotKey = nil
        let controller = HotKeySettings(current:config.hotkey) { [weak self] name in
            guard let self else { return }
            if let name {
                var next = self.config
                next.hotkey = name
                next.setupComplete = true
                if let error = next.save() { self.statusBar.showError(error) } else { self.config = next }
            }
            self.hotkeySettings = nil; self.resumeHotkeys()
        }
        hotkeySettings = controller; controller.present()
    }
    private func showTextSettings(assist: Bool = false) {
        guard phase == .idle, hotkeySettings == nil, textSettings == nil else { NSSound.beep(); return }
        corrections.stop(); hotKey?.stop(); hotKey = nil
        let controller = TextSettingsController(vocabulary:config.vocabulary,snippets:config.snippets,
            autoAddToDictionary:config.autoAddToDictionary,assistEnabled:config.ai.provider != "none",onSave:{ [weak self] words,snippets,enabled in
                guard let self else { return "Settings are no longer available." }
                var next = self.config; next.vocabulary = words; next.snippets = snippets; next.autoAddToDictionary = enabled
                if let error = next.save() { return error }
                self.config = next; self.corrections.enabled = enabled
                if !enabled { self.correctionSuggestion = nil; self.statusBar.setCorrectionAvailable(false) }
                return nil
            },onSuggest:{ [weak self] context,completion in
                guard let self, self.config.ai.provider != "none" else { completion(nil,"Choose an AI provider to request suggestions."); return }
                Task { @MainActor in
                    let result = await self.operations.perform(.init(operation:"snippet_assist",context:context))
                    guard self.textSettings != nil else { return }
                    completion(result.status == "ok" ? result.snippets : nil,result.status == "ok" ? nil : "Suggestions are unavailable. You can add a phrase manually.")
                }
            },onClose:{ [weak self] in
                guard let self else { return }; self.operations.cancel(); self.textSettings = nil; self.resumeHotkeys()
            })
        textSettings = controller; controller.present(showAssist:assist)
    }
    private func reviewCorrection() {
        guard phase == .idle, let word = correctionSuggestion else { return }
        corrections.stop()
        let alert = NSAlert(); alert.messageText = "Add this spelling to your vocabulary?"
        alert.informativeText = word; alert.addButton(withTitle:"Add spelling"); alert.addButton(withTitle:"Cancel")
        NSApp.activate(ignoringOtherApps:true)
        if alert.runModal() == .alertFirstButtonReturn {
            var next = config
            if !next.vocabulary.contains(word) { next.vocabulary.append(word) }
            if let error = next.save() { statusBar.showError(error) } else { config = next }
        }
        correctionSuggestion = nil; statusBar.setCorrectionAvailable(false)
    }

    // MARK: - Startup

    func reopen() { statusBar.reopenMenu() }

    func start() {
        Config.writeTemplateIfMissing()
        // Rewrites the file with every current key so new settings are
        // discoverable, preserving whatever the user set.
        if let error = config.save() { Log.write("config: settings could not be saved"); statusBar.showError(error) }
        Log.write("config: \(config.vocabulary.count) vocabulary terms, sound=\(config.sound ?? "default")")

        statusBar.setBackend(backendLabel)
        statusBar.setHotkey(config.hotkey)
        statusBar.onChangeHotkey = { [weak self] in self?.showHotkeySettings() }
        statusBar.onTextSettings = { [weak self] in self?.showTextSettings() }
        if config.ai.provider == "none" {
            statusBar.onSuggestSnippets = nil
        } else {
            statusBar.onSuggestSnippets = { [weak self] in self?.showTextSettings(assist:true) }
        }
        statusBar.onReviewCorrection = { [weak self] in self?.reviewCorrection() }
        corrections.enabled = config.autoAddToDictionary
        corrections.onSuggestion = { [weak self] word in
            self?.correctionSuggestion = word; self?.statusBar.setCorrectionAvailable(true)
        }
        statusBar.onCopyPending = { TextInserter.copyPendingToClipboard() }
        TextInserter.onPendingChanged = { [weak self] in
            self?.statusBar.setPendingText(TextInserter.hasPendingText)
        }
        statusBar.setCleanupEnabled(config.cleanupEnabled)
        statusBar.onQuit = { NSApp.terminate(nil) }
        statusBar.onToggleCleanup = { [weak self] in
            guard let self else { return }
            var next = config; next.cleanupEnabled.toggle()
            if let error = next.save() { statusBar.showError(error); return }
            config = next; statusBar.setCleanupEnabled(config.cleanupEnabled)
        }
        statusBar.onToggleLoginItem = { [weak self] in
            LoginItem.setEnabled(!LoginItem.isEnabled)
            self?.statusBar.refreshMenu()
        }

        cue.prepare(choice: config.sound, startFile: config.startSound, stopFile: config.stopSound,
                    reverbMix: config.cueReverb)
        statusBar.setSounds(Cue.available.map { (id: $0.id, title: $0.title) },
                            current: config.sound ?? Cue.defaultChoice)
        statusBar.onSelectSound = { [weak self] id in
            guard let self else { return }
            var next = config; next.sound = id
            if let error = next.save() { statusBar.showError(error); return }
            config = next
            cue.setSound(id)
            cue.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { self.cue.stop() }
        }

        // Absorb the one-time model warmup (measured 2.3-2.6 s on a fresh
        // process) now, so the first real dictation is not the slow one.
        let launchTranscriber = transcriber
        warmup = Task { await launchTranscriber.prepare() }

        // AXIsProcessTrusted is the honest check. tapCreate can succeed and
        // then silently deliver nothing, which looks identical to a working app
        // that ignores you.
        let trusted = AXIsProcessTrusted()
        Log.write("launch: bundle=\(Bundle.main.bundleURL.path) AXIsProcessTrusted=\(trusted) " +
                  "postEvent=\(CGPreflightPostEventAccess()) listenEvent=\(CGPreflightListenEventAccess())")

        let monitor = makeMonitor()
        let created = monitor?.start() == true
        Log.write("launch: tapCreate=\(created) cleanup=\(config.ai.provider)")

        if created && trusted {
            hotKey = monitor
        } else {
            monitor?.stop()
            requestAccessibility(tapCreated: created)
        }
        if !config.setupComplete {
            DispatchQueue.main.async { [weak self] in self?.showHotkeySettings() }
        }
    }

    // MARK: - Hotkey

    /// Returns false only for a gesture the app declines to act on.
    func handle(_ event: HotKeyEvent) -> Bool {
        switch event {
        case .begin:
            let accepted = beginRecording()
            if accepted { Log.write("hotkey: \(event)") }
            return accepted
        case .latch:
            return phase == .armed || phase == .recording
        case .commit, .unlatch:
            Log.write("hotkey: \(event)")
            finishRecording()
            return true
        case .discard:
            Log.write("hotkey: \(event)")
            discardRecording()
            return true
        }
    }

    @discardableResult
    private func beginRecording() -> Bool {
        if phase == .armed || phase == .recording { return true }
        guard phase == .idle else { return false }

        corrections.stop(); correctionSuggestion = nil; statusBar.setCorrectionAvailable(false)
        sessionFailure = nil; observationBaseline = nil

        // Nothing typeable under the cursor means the user wants Command for
        // something else. Decline the press outright: no sound, no mic, no
        // panel, and the release is ignored too.
        if config.requireTextField {
            let focus = TextFocus.probe()
            if !focus.certain {
                Log.write("hotkey: focus unsure (\(focus.description)), allowing")
            } else if !focus.accepts {
                Log.write("hotkey: ignored, focus is \(focus.description)")
                return false
            }
        }
        let binding = HotKeyBinding(config.hotkey) ?? HotKeyBinding("right-command")!
        FocusedElement.beginTrackingActivity { event in
            TextInserter.isOwnPasteEvent(event) || (!binding.isModifier && Int64(event.keyCode) == binding.keyCode
                && binding.matches(flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))))
        }
        insertionTarget = FocusedElement.captureTarget()
        if config.autoAddToDictionary { observationBaseline = SelectionSnapshot.emptyFieldBaseline() }
        Log.write("insert target: \(insertionTarget?.element == nil ? "window compatibility" : "Accessibility field")")
        sessionID &+= 1
        let id = sessionID
        phase = .armed

        // NOTHING user-visible happens until the delay elapses. Right Command
        // is an ordinary modifier, so acting on the press itself would chirp
        // the start chord and spawn a cleanup subprocess every time the user
        // hit Cmd-C. Everything below is committed to only once the key is
        // still down at +150 ms, by which point this is a real dictation.
        let work = DispatchWorkItem { [weak self] in
            guard let self, sessionID == id, phase == .armed else { return }
            pendingMicStart = nil
            phase = .recording
            Log.write("record: opening mic")
            cue.start()
            statusBar.showRecording()

            // Cleanup mode comes from whatever app is in front, decided before
            // the user speaks so the pre-warmed process has the right prompt.
            sessionMode = currentMode()

            let transcriber = self.transcriber
            arm(deadlines.opening, id, stage: "dictation did not start",
                message: "Dictation didn't start in time. Try again.")
            microphoneStart = Task { await self.openMicrophone(id, transcriber) }
        }
        pendingMicStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.micDelay, execute: work)
        return true
    }

    private func openMicrophone(_ id: Int, _ transcriber: Transcriber) async -> Bool {
        // Warmup and begin both create speech modules. Serialize them, including
        // when the first press arrives before the launch warmup has finished.
        await warmup?.value
        guard isCurrent(id, .recording), !Task.isCancelled else { return false }
        var step = OpeningStep.speech
        do {
            try await transcriber.begin()
            // From here on, giving up must release what begin() started: after
            // an abandon nothing else owns this transcriber. Finish and discard
            // await this task before their own cancel(), so calls never overlap.
            guard isCurrent(id, .recording), !Task.isCancelled else { await transcriber.cancel(); return false }
            let format = await transcriber.requiredFormat
            guard isCurrent(id, .recording), !Task.isCancelled else { await transcriber.cancel(); return false }
            step = .microphone
            // Buffers go to THIS session's transcriber, never a replacement.
            capture.onBuffer = { buffer in transcriber.feed(buffer) }
            try capture.start(convertingTo: format)
            // The mic is open; how long the user speaks is theirs.
            disarm()
            return true
        } catch {
            Log.write("record: FAILED to open \(step == .speech ? "speech engine" : "mic"): \(error)")
            // Stop/discard owns teardown once it changes phase. Otherwise an
            // opening failure must finish cancelling before another press.
            if isCurrent(id, .recording) {
                phase = .cancelling
                sessionFailure = step == .speech
                    ? "Speech recognition couldn't start. Try again in a moment."
                    : "The microphone is unavailable or switching. Try again."
                capture.stop()
                arm(deadlines.cancelling, id, stage: "cancel did not finish", message: nil)
                await transcriber.cancel()
                complete(id)
            } else {
                // Superseded while opening (released, discarded or abandoned).
                // A newer session may own the microphone; only the analyzer goes.
                await transcriber.cancel()
            }
            return false
        }
    }

    private enum OpeningStep { case speech, microphone }

    private func finishRecording() {
        if phase == .armed {
            completeSession()
            return
        }
        guard phase == .recording else { return }
        let id = sessionID
        phase = .processing
        pendingMicStart?.cancel()
        pendingMicStart = nil
        microphoneStart?.cancel()

        cue.stop()
        statusBar.showProcessing()
        capture.stop()
        arm(deadlines.transcribing, id, stage: "transcription did not finish",
            message: "Transcription stalled. Try again.")

        let opening = microphoneStart
        let mode = sessionMode
        let transcriber = self.transcriber
        Task {
            defer { complete(id) }
            // begin() can still be suspended when the user stops. Wait for it
            // before finishing/cancelling its analyzer, and never open the mic late.
            guard await opening?.value == true else {
                await transcriber.cancel()
                return
            }
            await transcribeAndInsert(id, transcriber, mode: mode)
        }
    }

    private func discardRecording() {
        if phase == .armed {
            completeSession()
            return
        }
        guard phase == .recording else { return }
        let id = sessionID
        phase = .cancelling
        pendingMicStart?.cancel()
        pendingMicStart = nil
        microphoneStart?.cancel()
        capture.stop()
        operations.cancel()
        arm(deadlines.cancelling, id, stage: "cancel did not finish", message: nil)
        let opening = microphoneStart
        let transcriber = self.transcriber
        Task {
            _ = await opening?.value
            await transcriber.cancel()
            complete(id)
        }
    }

    /// Completes session `id` unless a deadline already abandoned it.
    private func complete(_ id: Int) {
        guard sessionID == id, phase != .idle else { return }
        completeSession()
    }

    private func isCurrent(_ id: Int, _ expected: Phase) -> Bool { sessionID == id && phase == expected }

    // MARK: - Deadlines

    /// One deadline at a time: each stage replaces the previous stage's.
    private func arm(_ seconds: TimeInterval, _ id: Int, stage: String, message: String?) {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.abandon(id, stage: stage, message: message)
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func disarm() {
        watchdog?.cancel()
        watchdog = nil
    }

    /// A stage overran. The stuck work keeps its own transcriber, which is
    /// replaced rather than cancelled here: the abandoned analyzer may still be
    /// running, and the transcriber is not safe to call from two tasks at once.
    /// The stuck task releases it itself if it ever returns (openMicrophone),
    /// and late words are kept in Copy pending text (retainLate).
    private func abandon(_ id: Int, stage: String, message: String?) {
        guard sessionID == id, phase != .idle else { return }
        Log.write("watchdog: \(stage) in time; session reset")
        transcriber = makeTranscriber()
        // A stalled launch warmup must not hold the next session too.
        warmup = nil
        pendingMicStart?.cancel()
        microphoneStart?.cancel()
        capture.stop()
        operations.cancel()
        if let message { sessionFailure = message }
        completeSession()
    }

    /// One exit for every completed, empty, failed, or discarded session.
    private func completeSession() {
        #if SESSION_RECOVERY_TESTS
        testingLastMessage = sessionFailure
        #endif
        disarm()
        pendingMicStart?.cancel()
        pendingMicStart = nil
        microphoneStart = nil
        operations.cancel()
        phase = .idle
        insertionTarget = nil
        FocusedElement.endTrackingActivity()
        hotKey?.resetGesture()
        if let sessionFailure { statusBar.showError(sessionFailure) } else { statusBar.showIdle() }
    }

    // MARK: - The pipeline

    private func transcribeAndInsert(_ id: Int, _ transcriber: Transcriber, mode: CleanupMode) async {
        let raw: String
        do {
            raw = try await transcriber.finish()
        } catch {
            Log.write("transcribe: FAILED \(error)")
            await transcriber.cancel()
            return
        }
        guard isCurrent(id, .processing) else { retainLate(raw); return }
        Log.write("transcribe: \(raw.count) chars")
        guard !raw.isEmpty else { return }
        arm(deadlines.finishing, id, stage: "cleanup or insertion did not finish",
            message: "Sona stalled finishing that dictation. Try again.")

        // Dictation retains the exact raw local text on any cleanup failure.
        let request = BridgeRequest(operation:"dictate",transcript:raw,
            mode:mode == .strict ? "strict" : "prose",cleanupEnabled:config.cleanupEnabled)
        let result = await operations.perform(request)
        guard isCurrent(id, .processing) else { retainLate(raw); return }
        let text = result.insertionText(raw:raw,isRewrite:false) ?? raw
        let method = TextInserter.insert(text,into:insertionTarget)
        // The text is placed; only fixed pauses follow.
        disarm()
        Log.write("insert: \(method.rawValue) (\(text.count) chars)")
        if let reason = TextInserter.lastPendingReason { Log.write("insert blocked: \(reason.diagnosticCode)") }
        if method == .pending {
            sessionFailure = "Text is ready in Copy pending text."
        }
        if method == .paste {
            try? await Task.sleep(for:.milliseconds(250))
            if isCurrent(id, .processing), config.autoAddToDictionary, let baseline = observationBaseline {
                corrections.verifyAndBegin(text:text,before:baseline)
            }
            try? await Task.sleep(for:.milliseconds(200))
        }
    }

    /// A session its deadline abandoned can still finish. Its words go to Copy
    /// pending text only: a nil target never pastes into whatever is focused now.
    private func retainLate(_ text: String) {
        guard !text.isEmpty else { return }
        TextInserter.insert(text, into: nil)
        Log.write("transcribe: late result retained (\(text.count) chars)")
        // Only while nothing newer owns the panel.
        if phase == .idle { statusBar.showError("Text is ready in Copy pending text.") }
    }

    #if SESSION_RECOVERY_TESTS
    var testingPhase: String { "\(phase)" }
    private(set) var testingLastMessage: String?
    #endif

    // MARK: - Context

    private func currentMode() -> CleanupMode {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        else { return .prose }
        return config.strictModeBundleIDs.contains(bundleID) ? .strict : .prose
    }

    /// Asks the SYSTEM for the grant rather than showing our own alert, and
    /// keeps running so that granting it does not require finding the app
    /// again. A menu bar app that quits on first launch is a menu bar app the
    /// user never sees a second time.
    private func requestAccessibility(tapCreated: Bool) {
        Log.write("permission: requesting Accessibility (tapCreated=\(tapCreated))")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        statusBar.setBackend("needs Accessibility")

        // Poll for the grant. TCC does not notify, and the user is expected to
        // be in System Settings right now.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            Task { @MainActor in
                guard let self, self.hotKey == nil else { return }
                let monitor = self.makeMonitor()
                if monitor?.start() == true {
                    self.hotKey = monitor
                    self.statusBar.setBackend(
                        self.backendLabel)
                    Log.write("permission: granted, hotkey armed")
                }
            }
        }
    }

}
