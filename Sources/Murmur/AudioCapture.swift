import AVFoundation
import Accelerate
import Foundation

/// Microphone capture for one dictation.
///
/// The mic is opened on key-down and closed on commit. It is never held open
/// between dictations.
///
/// On update rate: `installTap` is capped at ~10 Hz. Measured on this machine,
/// requesting bufferSize 256, 512 or 1024 all yielded 4410-frame buffers at
/// 100.07 ms intervals. That is too coarse to drive a waveform directly, so the
/// level it produces is treated as an ENVELOPE and the view interpolates
/// between samples at display rate. Dropping to a raw AUHAL render callback
/// would give 94 Hz, at the cost of manual format negotiation (the built-in mic
/// reports 48 kHz hardware against AVAudioEngine's claimed 44.1 kHz, and
/// getting that wrong returns kAudioUnitErr_CannotDoInCurrentContext).
final class AudioCapture {

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

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var running = false

    /// - Parameter format: what the transcription engine wants. Buffers are
    ///   converted into it before `onBuffer` fires.
    func start(convertingTo format: AVAudioFormat?) throws {
        guard !running else { return }
        targetFormat = format

        let input = engine.inputNode
        // Always ask the node for its real format. The hardware format and the
        // node's advertised format do not always agree, and guessing throws.
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0 else {
            throw TranscriptionError.unavailable("microphone reported no format")
        }

        if let format, format != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: format)
        } else {
            converter = nil
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        converter = nil
        setLevel(0)
    }

    // MARK: - Audio thread

    private func process(_ buffer: AVAudioPCMBuffer) {
        updateLevel(from: buffer)
        updateSpectrum(from: buffer)

        guard let targetFormat, let converter else {
            onBuffer?(buffer)
            return
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, converted.frameLength > 0 else { return }
        onBuffer?(converted)
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
