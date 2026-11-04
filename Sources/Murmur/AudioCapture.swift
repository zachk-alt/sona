import AVFoundation
import Accelerate
import AppKit
import Foundation

/// What a dictation session needs from the microphone. Tests substitute it.
protocol AudioCapturing: AnyObject {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var onSpectrum: (([Float]) -> Void)? { get set }
    func start(convertingTo format: AVAudioFormat?) throws
    func stop()
}

/// Microphone capture for one dictation.
///
/// The mic is opened on key-down and closed on commit. It is never held open
/// between dictations.
///
/// AVAudioEngine reports some failures by RAISING an Objective-C exception
/// instead of throwing: when the microphone is busy or switching (another app
/// holding it, a Bluetooth headset changing profile), `installTap` raises
/// "Failed to create tap due to format mismatch". Uncaught on the main
/// thread, AppKit swallowed it and the main queue never ran again, so every
/// later key press did nothing until Sona was quit and reopened. Every
/// framework call that can raise is wrapped in `catchingFrameworkException`,
/// and a failed open throws the engine away so the next press starts clean.
///
/// On update rate: `installTap` is capped at ~10 Hz. Measured on this machine,
/// requesting bufferSize 256, 512 or 1024 all yielded 4410-frame buffers at
/// 100.07 ms intervals. That is too coarse to drive a waveform directly, so the
/// level it produces is treated as an ENVELOPE and the view interpolates
/// between samples at display rate. Dropping to a raw AUHAL render callback
/// would give 94 Hz, at the cost of manual format negotiation (the built-in mic
/// reports 48 kHz hardware against AVAudioEngine's claimed 44.1 kHz, and
/// getting that wrong returns kAudioUnitErr_CannotDoInCurrentContext).
final class AudioCapture: AudioCapturing {

    /// 0...1, updated ~10x/sec. Read from the main thread by the waveform.
    private(set) var level: Float = 0

    /// Called on the audio thread with converted buffers ready for the engine.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Called on the main thread when `level` changes.
    var onLevel: ((Float) -> Void)?
    /// Called on the main thread with `bandCount` values 0...1, low to high.
    var onSpectrum: (([Float]) -> Void)?

    static let bandCount = 48
    private static let analysisFrames = 1024
    /// Log-spaced band centers over the voice range.
    private static let bandFrequencies: [Float] = (0..<bandCount).map { i in
        80 * pow(6000 / 80, Float(i) / Float(bandCount - 1))
    }
    private static let window: [Float] = {
        var w = [Float](repeating: 0, count: analysisFrames)
        vDSP_hann_window(&w, vDSP_Length(analysisFrames), Int32(vDSP_HANN_NORM))
        return w
    }()

    /// Reused between dictations while healthy: a warm engine opens the mic
    /// about 90 ms sooner than a new one (measured 2026-10-06, 210-240 ms vs
    /// 300-360 ms from start to first buffer). A failed open, a device change
    /// or a start that delivers no audio throws it away, so the next open is fresh.
    private var engine: AVAudioEngine?
    private var running = false
    /// Shared by the audio thread (conversion) and main (open, stop, flush).
    private let converterLock = NSLock()
    private var converter: CaptureConverter?
    private var targetFormat: AVAudioFormat?
    private var configurationObserver: NSObjectProtocol?
    private var stallTimer: Timer?
    private let framesLock = NSLock()
    private var framesDelivered = 0
    private var framesAtLastCheck = 0
    /// Frames delivered when the current engine opened, and when that was.
    private var framesAtOpen = 0
    private var openedAt = Date.distantPast
    /// Mid-dictation reopens so far, capped so a device that keeps
    /// reconfiguring cannot loop. Read by the recovery tests.
    private(set) var reopenCount = 0
    private static let maximumReopens = 3
    /// Buffers arrive every ~100 ms even in silence, so a running dictation
    /// that delivers nothing for this long has lost its microphone.
    private static let stallInterval: TimeInterval = 1.2
    /// A freshly opened mic may take seconds to send its first buffer (a
    /// Bluetooth headset switching to its microphone profile). It is not
    /// judged silent before this.
    private static let firstBufferGrace: TimeInterval = 4
    private var wakeObserver: NSObjectProtocol?

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.discardIdleEngine()
        }
    }

    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// - Parameter format: what the transcription engine wants. Buffers are
    ///   converted into it before `onBuffer` fires.
    func start(convertingTo format: AVAudioFormat?) throws {
        guard !running else { return }
        converterLock.withLock { targetFormat = format }
        reopenCount = 0
        let reused = engine != nil
        do {
            try open(convertingTo: format)
        } catch where reused {
            // A reused engine can go stale across sleep or a device change
            // (2026-10-05: display sleep broke its device aggregate). The
            // failed open discarded it, so this retry builds a fresh one.
            Log.write("record: reused mic engine failed (\(error)); retrying with a fresh one")
            try open(convertingTo: format)
        }
        running = true
        startStallWatch()
    }

    /// The Mac woke: an idle engine kept from before sleep may be bound to
    /// devices that no longer exist, so the next press builds a fresh one.
    private func discardIdleEngine() {
        guard !running, let engine else { return }
        self.engine = nil
        discard(engine)
    }

    func stop() {
        guard running else { return }
        running = false
        stopStallWatch()
        stopObserving()
        if let engine {
            do {
                try catchingFrameworkException {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                }
            } catch {
                Log.write("record: mic teardown raised \(error)")
                self.engine = nil
            }
        }
        // The converter holds back the last few milliseconds of audio (0 to
        // 78 ms measured). Hand them to the engine before closing.
        deliverTail(replacingConverterWith: nil)
        setLevel(0)
    }

    /// Flushes the current converter's held-back audio to `onBuffer`, then
    /// installs `next`. Called on main; the lock keeps the audio thread out.
    private func deliverTail(replacingConverterWith next: CaptureConverter?) {
        let tail = converterLock.withLock { () -> [AVAudioPCMBuffer] in
            let held = converter?.flush() ?? []
            converter = next
            return held
        }
        tail.forEach { onBuffer?($0) }
    }

    /// Taps and starts the current engine, or a new one when there is none.
    /// Throws with nothing running and that engine discarded.
    private func open(convertingTo format: AVAudioFormat?) throws {
        let engine = self.engine ?? AVAudioEngine()
        do {
            let input = try catchingFrameworkException { engine.inputNode }
            // Always ask the node for its real format. The hardware format and the
            // node's advertised format do not always agree, and guessing throws.
            let sourceFormat = input.outputFormat(forBus: 0)
            guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
                throw TranscriptionError.unavailable("microphone reported no format")
            }

            // A reopen hands on what the previous device's converter held.
            if let format, format != sourceFormat {
                deliverTail(replacingConverterWith: try CaptureConverter(from: sourceFormat, to: format))
            } else {
                deliverTail(replacingConverterWith: nil)
            }

            try catchingFrameworkException {
                input.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { [weak self] buffer, _ in
                    self?.process(buffer)
                }
            }
            try catchingFrameworkException {
                engine.prepare()
                try engine.start()
            }
        } catch {
            discard(engine)
            self.engine = nil
            converterLock.withLock { converter = nil }
            throw error
        }
        self.engine = engine
        framesAtOpen = framesLock.withLock { framesDelivered }
        openedAt = Date()
        observeConfigurationChanges(of: engine)
    }

    /// Removes the tap and stops an engine that is being thrown away. A
    /// framework exception here is logged, never rethrown.
    private func discard(_ engine: AVAudioEngine) {
        do {
            try catchingFrameworkException {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        } catch {
            Log.write("record: mic teardown raised \(error)")
        }
    }

    /// AVAudioEngine stops itself when the input device changes while it runs
    /// (a headset connecting mid-sentence). Reopen on the new device so the
    /// rest of the dictation is still heard; earlier audio is already with
    /// the transcriber.
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        stopObserving()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak engine] _ in
            guard let self, let engine, self.running, self.engine === engine, !engine.isRunning else { return }
            self.reopen(engine, reason: "input device changed")
        }
    }

    private func stopObserving() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }

    /// Some losses post no configuration change (another app taking the mic
    /// exclusively, a Bluetooth link dropping). Once a second, a dictation
    /// whose buffers stopped arriving, or whose last reopen failed, reopens.
    private func startStallWatch() {
        stopStallWatch()
        framesAtLastCheck = framesLock.withLock { framesDelivered }
        let timer = Timer(timeInterval: Self.stallInterval, repeats: true) { [weak self] _ in
            self?.checkForStall()
        }
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
    }

    private func stopStallWatch() {
        stallTimer?.invalidate()
        stallTimer = nil
    }

    private func checkForStall() {
        guard running else { stopStallWatch(); return }
        let delivered = framesLock.withLock { framesDelivered }
        let stalled: Bool
        if engine == nil {
            stalled = true   // the last reopen failed: try again
        } else if delivered == framesAtOpen {
            stalled = Date().timeIntervalSince(openedAt) >= Self.firstBufferGrace
        } else {
            stalled = delivered == framesAtLastCheck
        }
        framesAtLastCheck = delivered
        guard stalled else { return }
        guard reopenCount < Self.maximumReopens else {
            stopStallWatch()
            Log.write("record: mic still silent, left closed for this dictation")
            return
        }
        reopen(engine, reason: engine == nil ? "mic was closed" : "mic stopped delivering audio")
    }

    /// Replaces a dead (or already discarded) engine mid-dictation with a
    /// fresh one on the current device.
    private func reopen(_ dead: AVAudioEngine?, reason: String) {
        stopObserving()
        if let dead { discard(dead) }
        engine = nil
        guard reopenCount < Self.maximumReopens else {
            Log.write("record: \(reason) again, mic left closed for this dictation")
            return
        }
        reopenCount += 1
        do {
            try open(convertingTo: targetFormat)
            // Judge the new engine by a full window from its own start.
            startStallWatch()
            Log.write("record: \(reason), mic reopened")
        } catch {
            Log.write("record: \(reason), reopen failed: \(error)")
        }
    }

    // MARK: - Audio thread

    private func process(_ buffer: AVAudioPCMBuffer) {
        framesLock.withLock { framesDelivered &+= Int(buffer.frameLength) }
        updateLevel(from: buffer)
        updateSpectrum(from: buffer)

        let output: AVAudioPCMBuffer? = converterLock.withLock {
            if let converter { return converter.convert(buffer) }
            // No converter: only a buffer already in the engine's format may
            // pass. One that arrives as the mic closes is dropped, never fed
            // to the engine at the wrong rate.
            if let targetFormat, buffer.format != targetFormat { return nil }
            return buffer
        }
        guard let output else { return }
        onBuffer?(output)
    }

    /// RMS over the first channel. vDSP_rmsqv measured 243-276 ns per buffer,
    /// so this is free.
    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))

        // Speech RMS sits well below 1.0, so map through dB and clamp to a
        // usable floor rather than showing a permanently flat bar.
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = max(0, min(1, (db + 50) / 50))
        setLevel(normalized)
    }

    /// Per-band energy via Goertzel on the last 1024 samples. 48 bands x 1024
    /// is ~50k multiply-adds per buffer at 10 buffers/s: nothing. A tilt lifts
    /// the highs, which carry far less energy than the lows in speech but are
    /// where consonants live; without it the right half of the display never
    /// moves.
    private func updateSpectrum(from buffer: AVAudioPCMBuffer) {
        let n = Self.analysisFrames
        guard onSpectrum != nil, let channel = buffer.floatChannelData?[0],
              Int(buffer.frameLength) >= n else { return }
        let sampleRate = Float(buffer.format.sampleRate)
        let start = Int(buffer.frameLength) - n
        var x = [Float](repeating: 0, count: n)
        vDSP_vmul(channel + start, 1, Self.window, 1, &x, 1, vDSP_Length(n))

        var bands = [Float](repeating: 0, count: Self.bandCount)
        for (b, f) in Self.bandFrequencies.enumerated() {
            let k = 2 * Float.pi * f / sampleRate
            let coeff = 2 * cos(k)
            var s1: Float = 0, s2: Float = 0
            for i in 0..<n {
                let s0 = x[i] + coeff * s1 - s2
                s2 = s1
                s1 = s0
            }
            let power = max(0, s1 * s1 + s2 * s2 - coeff * s1 * s2)
            let magnitude = power.squareRoot() / Float(n) * 2
            let tilt = pow(f / 250, 0.55)
            let db = 20 * log10(max(magnitude * tilt, 1e-7))
            // Speech at normal volume should reach most of the bar height.
            bands[b] = max(0, min(1, (db + 66) / 38))
        }
        DispatchQueue.main.async { [weak self] in
            self?.onSpectrum?(bands)
        }
    }

    private func setLevel(_ value: Float) {
        level = value
        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(value)
        }
    }
}

/// Converts microphone buffers into the speech engine's format.
///
/// Runs at the converter's highest quality: the Mastering algorithm ("higher
/// quality range, more expensive", AudioConverter.h) at AVAudioQuality.max.
/// The default (Normal) dulled the highest frequencies a little. A sample-rate
/// converter holds back a few milliseconds of audio between calls; `flush`
/// returns them once input has ended, so the last sound before stop is heard.
final class CaptureConverter {
    let format: AVAudioFormat
    private let converter: AVAudioConverter
    private var ended = false

    init(from source: AVAudioFormat, to target: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw TranscriptionError.unavailable("no converter from the microphone format to the speech format")
        }
        try catchingFrameworkException {
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        }
        self.converter = converter
        self.format = target
    }

    var algorithm: String? { converter.sampleRateConverterAlgorithm }
    var quality: Int { converter.sampleRateConverterQuality }

    /// One microphone buffer in, whatever the converter releases out.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard !ended, let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity(for: buffer.frameLength, from: buffer.format))
        else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, status != .error, converted.frameLength > 0 else { return nil }
        return converted
    }

    /// Ends the input and returns the audio the converter was still holding.
    /// The converter takes no more input afterwards.
    func flush() -> [AVAudioPCMBuffer] {
        guard !ended else { return [] }
        ended = true
        var tail: [AVAudioPCMBuffer] = []
        // Each pass drains up to a quarter second; the held audio is far less.
        for _ in 0..<8 {
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, format.sampleRate / 4)))
            else { break }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            if error == nil, status != .error, out.frameLength > 0 { tail.append(out) }
            if error != nil || status != .haveData || out.frameLength == 0 { break }
        }
        return tail
    }

    private func capacity(for frames: AVAudioFrameCount, from source: AVAudioFormat) -> AVAudioFrameCount {
        AVAudioFrameCount(Double(frames) * format.sampleRate / source.sampleRate) + 1024
    }
}
