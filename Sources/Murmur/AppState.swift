import AppKit
import AVFoundation
import Foundation

/// Wires the hotkey to the microphone, the transcriber, the cleanup pass and
/// the focused text field.
@MainActor
final class AppState {

    /// The microphone is opened this long after the key goes down, not
    /// instantly. Right-Command is also an ordinary modifier, so opening on
    /// every press would flash the orange recording indicator every time the
    /// user hits Cmd-C. The start chord plays immediately and takes ~90 ms, so
    /// by the time anyone begins speaking the mic is already live.
    private static let micDelay: TimeInterval = 0.15

    private var config: Config
    private let statusBar = StatusBarController()
    private let cue = Cue()
    private let capture = AudioCapture()
    private let transcriber: Transcriber = AppleTranscriber()
    private var cleanup: CleanupService
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

    init() {
        config = Config.load()
        let selected = Self.makeCleanup(config)
        cleanup = selected.0
        backendLabel = selected.1
    }

    private static func makeCleanup(_ config: Config) -> (CleanupService, String) {
        if config.ai.provider == "none" { return (PassthroughCleanupService(), "Plain dictation") }
        if ["auto", "claude"].contains(config.ai.provider), config.ai.model == "economy",
           let service = ClaudeCleanupService(vocabulary:config.vocabulary, overridePath:config.ai.executable ?? config.claudePath) {
            return (service, "Claude CLI (Haiku)")
        }
        let resources = Bundle.main.resourceURL
        let bridge = resources?.appendingPathComponent("bridge/sona-cleanup.mjs")
            ?? URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("bridge/sona-cleanup.mjs")
        let bundledNode = resources?.appendingPathComponent("runtime/node").path
        let node = bundledNode.flatMap { FileManager.default.isExecutableFile(atPath:$0) ? $0 : nil } ?? CLIResolver.resolve("node")
        guard let node, FileManager.default.fileExists(atPath:bridge.path) else {
            return (PassthroughCleanupService(), "Plain dictation (AI runtime unavailable)")
        }
        return (BridgeCleanupService(configPath:Config.configURL.path, bridgePath:bridge.path, nodePath:node, timeout:Double(config.ai.timeoutMs)/1000+2),
                config.ai.provider == "auto" ? "Automatic CLI, economy model" : "\(config.ai.provider.capitalized), \(config.ai.model)")
    }

    private func showHotkeySettings() {
        guard phase == .idle, hotkeySettings == nil else { NSSound.beep(); return }
        hotKey?.stop(); hotKey = nil
        let controller = HotKeySettings(current:config.hotkey) { [weak self] name in
            guard let self else { return }
            if let name { self.config.hotkey = name; self.config.setupComplete = true; self.config.save() }
            self.hotkeySettings = nil
            self.statusBar.setHotkey(self.config.hotkey)
            let monitor = HotKeyMonitor(binding:HotKeyBinding(self.config.hotkey) ?? HotKeyBinding("right-command")!) { [weak self] event in self?.handle(event) ?? false }
            if monitor.start() { self.hotKey = monitor }
        }
        hotkeySettings = controller
        controller.present()
    }

    // MARK: - Startup

    func start() {
        Config.writeTemplateIfMissing()
        // Rewrites the file with every current key so new settings are
        // discoverable, preserving whatever the user set.
        config.save()
        Log.write("config: \(config.vocabulary.count) vocabulary terms, sound=\(config.sound ?? "default")")

        statusBar.setBackend(backendLabel)
        statusBar.setHotkey(config.hotkey)
        statusBar.onChangeHotkey = { [weak self] in self?.showHotkeySettings() }
        statusBar.onCopyPending = { TextInserter.copyPendingToClipboard() }
        TextInserter.onPendingChanged = { [weak self] in
            self?.statusBar.setPendingText(TextInserter.hasPendingText)
        }
        statusBar.setCleanupEnabled(config.cleanupEnabled)
        statusBar.onQuit = { NSApp.terminate(nil) }
        statusBar.onToggleCleanup = { [weak self] in
            guard let self else { return }
            config.cleanupEnabled.toggle()
            config.save()
            statusBar.setCleanupEnabled(config.cleanupEnabled)
        }
        statusBar.onToggleLoginItem = { [weak self] in
            LoginItem.setEnabled(!LoginItem.isEnabled)
            self?.statusBar.refreshMenu()
        }

        capture.onLevel = { [weak self] level in
            guard let self, phase == .recording else { return }
            statusBar.setLevel(level)
        }
        capture.onSpectrum = { [weak self] bands in
            guard let self, phase == .recording else { return }
            statusBar.setSpectrum(bands)
        }
        capture.onBuffer = { [weak self] buffer in
            self?.transcriber.feed(buffer)
        }

        cue.prepare(choice: config.sound, startFile: config.startSound, stopFile: config.stopSound,
                    reverbMix: config.cueReverb)
        statusBar.setSounds(Cue.available.map { (id: $0.id, title: $0.title) },
                            current: config.sound ?? Cue.defaultChoice)
        statusBar.onSelectSound = { [weak self] id in
            guard let self else { return }
            config.sound = id
            config.save()
            cue.setSound(id)
            cue.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { self.cue.stop() }
        }

        // Absorb the one-time model warmup (measured 2.3-2.6 s on a fresh
        // process) now, so the first real dictation is not the slow one.
        warmup = Task { await transcriber.prepare() }

        // AXIsProcessTrusted is the honest check. tapCreate can succeed and
        // then silently deliver nothing, which looks identical to a working app
        // that ignores you.
        let trusted = AXIsProcessTrusted()
        Log.write("launch: bundle=\(Bundle.main.bundleURL.path) AXIsProcessTrusted=\(trusted) " +
                  "postEvent=\(CGPreflightPostEventAccess()) listenEvent=\(CGPreflightListenEventAccess())")

        let monitor = HotKeyMonitor(binding: HotKeyBinding(config.hotkey) ?? HotKeyBinding("right-command")!) { [weak self] event in
            self?.handle(event) ?? false
        }
        let created = monitor.start()
        Log.write("launch: tapCreate=\(created) cleanup=\(config.ai.provider)")

        if created && trusted {
            hotKey = monitor
        } else {
            monitor.stop()
            requestAccessibility(tapCreated: created)
        }
        if !config.setupComplete {
            DispatchQueue.main.async { [weak self] in self?.showHotkeySettings() }
        }
    }

    // MARK: - Hotkey

    /// Returns false only for a `.begin` the app declines to act on.
    private func handle(_ event: HotKeyEvent) -> Bool {
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
            !binding.isModifier && Int64(event.keyCode) == binding.keyCode
                && binding.matches(flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
        }
        insertionTarget = FocusedElement.captureTarget()
        Log.write("insert target: \(insertionTarget?.element == nil ? "window compatibility" : "Accessibility field")")
        phase = .armed

        // NOTHING user-visible happens until the delay elapses. Right Command
        // is an ordinary modifier, so acting on the press itself would chirp
        // the start chord and spawn a cleanup subprocess every time the user
        // hit Cmd-C. Everything below is committed to only once the key is
        // still down at +150 ms, by which point this is a real dictation.
        let work = DispatchWorkItem { [weak self] in
            guard let self, phase == .armed else { return }
            pendingMicStart = nil
            phase = .recording
            Log.write("record: opening mic")
            cue.start()
            statusBar.showRecording()

            // Cleanup mode comes from whatever app is in front, decided before
            // the user speaks so the pre-warmed process has the right prompt.
            sessionMode = currentMode()
            if config.cleanupEnabled {
                cleanup.prewarm(mode: sessionMode)
            }
            microphoneStart = Task { await self.openMicrophone() }
        }
        pendingMicStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.micDelay, execute: work)
        return true
    }

    private func openMicrophone() async -> Bool {
        // Warmup and begin both create speech modules. Serialize them, including
        // when the first press arrives before the launch warmup has finished.
        await warmup?.value
        guard phase == .recording, !Task.isCancelled else { return false }
        do {
            try await transcriber.begin()
            guard phase == .recording, !Task.isCancelled else { return false }
            let format = await transcriber.requiredFormat
            guard phase == .recording, !Task.isCancelled else { return false }
            try capture.start(convertingTo: format)
            return true
        } catch {
            Log.write("record: FAILED to open mic: \(error)")
            // Stop/discard owns teardown once it changes phase. Otherwise an
            // opening failure must finish cancelling before another press.
            if phase == .recording {
                phase = .cancelling
                capture.stop()
                await transcriber.cancel()
                completeSession()
            }
            return false
        }
    }

    private func finishRecording() {
        if phase == .armed {
            completeSession()
            return
        }
        guard phase == .recording else { return }
        phase = .processing
        pendingMicStart?.cancel()
        pendingMicStart = nil
        microphoneStart?.cancel()

        cue.stop()
        statusBar.showProcessing()
        capture.stop()

        let opening = microphoneStart
        let mode = sessionMode
        Task {
            defer { completeSession() }
            // begin() can still be suspended when the user stops. Wait for it
            // before finishing/cancelling its analyzer, and never open the mic late.
            guard await opening?.value == true else {
                await transcriber.cancel()
                return
            }
            await transcribeAndInsert(mode: mode)
        }
    }

    private func discardRecording() {
        if phase == .armed {
            completeSession()
            return
        }
        guard phase == .recording else { return }
        phase = .cancelling
        pendingMicStart?.cancel()
        pendingMicStart = nil
        microphoneStart?.cancel()
        capture.stop()
        cleanup.shutdown()
        let opening = microphoneStart
        Task {
            _ = await opening?.value
            await transcriber.cancel()
            completeSession()
        }
    }

    /// One exit for every completed, empty, failed, or discarded session.
    private func completeSession() {
        pendingMicStart?.cancel()
        pendingMicStart = nil
        microphoneStart = nil
        cleanup.shutdown()
        phase = .idle
        insertionTarget = nil
        FocusedElement.endTrackingActivity()
        hotKey?.resetGesture()
        statusBar.showIdle()
    }

    // MARK: - The pipeline

    private func transcribeAndInsert(mode: CleanupMode) async {
        let raw: String
        do {
            raw = try await transcriber.finish()
        } catch {
            Log.write("transcribe: FAILED \(error)")
            await transcriber.cancel()
            return
        }
        Log.write("transcribe: \(raw.count) chars")
        guard !raw.isEmpty else { return }

        // Cleanup is an enhancement, never a dependency. Any failure, timeout
        // or missing CLI falls through to the words the user actually said.
        var text = raw
        if config.cleanupEnabled {
            do {
                text = try await cleanup.clean(raw, mode: mode)
            } catch {
                let reason: String
                switch error {
                case CleanupError.unavailable: reason = "CLI unavailable"
                case CleanupError.timedOut: reason = "timed out"
                case CleanupError.badResponse: reason = "invalid response"
                case is CancellationError: reason = "cancelled"
                default: reason = "failed"
                }
                Log.write("cleanup: \(reason), using raw transcript")
            }
        }

        let method = TextInserter.insert(text, into: insertionTarget)
        Log.write("insert: \(method.rawValue) \(text.count) chars")
        if method == .paste {
            // The target can read the pasteboard up to 385 ms after Cmd-V.
            // Keep processing visible until that asynchronous insertion settles.
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
    }

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
                let monitor = HotKeyMonitor(binding: HotKeyBinding(self.config.hotkey) ?? HotKeyBinding("right-command")!) { [weak self] event in
                    self?.handle(event) ?? false
                }
                if monitor.start() {
                    self.hotKey = monitor
                    self.statusBar.setBackend(
                        self.backendLabel)
                    Log.write("permission: granted, hotkey armed")
                }
            }
        }
    }

}
