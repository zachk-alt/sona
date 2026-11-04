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

/// M6: one text-free line per finished dictation. Only numbers, the input
/// device name and fixed codes; never transcript or cleaned text.
enum SessionMetrics {
    /// Share of the engine's words that cleanup changed, as a whole percent,
    /// from the word-level edit distance. 0 when cleanup returned nothing.
    static func changedPercent(raw: String, cleaned: String?) -> Int {
        guard let cleaned else { return 0 }
        let a = words(raw), b = words(cleaned)
        guard !a.isEmpty else { return b.isEmpty ? 0 : 100 }
        let distance = wordEditDistance(a, b)
        return Int((Double(min(distance, a.count)) / Double(a.count) * 100).rounded())
    }

    static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
    }

    /// Levenshtein distance over words (insert, delete, substitute).
    static func wordEditDistance(_ a: [Substring], _ b: [Substring]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    static func line(keyToFirstAudioMs: Int?, firstAudioDbfs: Double?, inputDevice: String?, holdMs: Int?,
                     cleanupStatus: String, reason: String?, changedPercent: Int) -> String {
        func number(_ v: Int?) -> String { v.map(String.init) ?? "none" }
        let level = firstAudioDbfs.map { String(Int($0.rounded())) } ?? "none"
        // A device name is a label, not text the user dictated. Quote it so
        // spaces cannot shift the fields.
        let device = inputDevice.map { "\"" + $0.replacingOccurrences(of: "\"", with: "'") + "\"" } ?? "none"
        return "session: firstAudioMs=\(number(keyToFirstAudioMs)) firstAudioDbfs=\(level) device=\(device) " +
            "holdMs=\(number(holdMs)) cleanup=\(cleanupStatus) reason=\(reason ?? "none") wordsChanged=\(changedPercent)%"
    }
}
