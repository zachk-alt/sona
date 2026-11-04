import AVFoundation
import Accelerate
import Foundation

/// Lets exactly one caller through: the first audio buffer of a session.
/// Claimed on the audio thread.
final class FirstAudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}

enum AudioLevel {
    /// Floor for digital silence.
    static let silence = -160.0

    /// RMS level of a buffer in dBFS (0 is full scale). Reads 32-bit float,
    /// 16-bit and 32-bit integer PCM, the formats the speech engine and the
    /// microphone tap use. Only the number leaves this function.
    static func dbfs(_ buffer: AVAudioPCMBuffer) -> Double {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return silence }
        // Interleaved data keeps every channel in the first pointer.
        let count = buffer.format.isInterleaved ? frames * Int(buffer.format.channelCount) : frames
        var rms: Float = 0
        if let samples = buffer.floatChannelData?[0] {
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        } else if let samples = buffer.int16ChannelData?[0] {
            var floats = [Float](repeating: 0, count: count)
            vDSP_vflt16(samples, 1, &floats, 1, vDSP_Length(count))
            vDSP_rmsqv(floats, 1, &rms, vDSP_Length(count))
            rms /= Float(Int16.max) + 1
        } else if let samples = buffer.int32ChannelData?[0] {
            var floats = [Float](repeating: 0, count: count)
            vDSP_vflt32(samples, 1, &floats, 1, vDSP_Length(count))
            vDSP_rmsqv(floats, 1, &rms, vDSP_Length(count))
            rms /= Float(Int32.max) + 1
        } else {
            return silence
        }
        guard rms.isFinite, rms > 0 else { return silence }
        return max(silence, 20 * log10(Double(rms)))
    }
}
