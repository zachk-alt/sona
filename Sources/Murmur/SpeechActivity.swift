import Foundation

/// Decides whether a recording holds speech from short windows, not the
/// whole-recording average. A Swift port of windows/src/Sona.Core/SpeechActivity.cs
/// with the same constants: the quietest windows set the room's noise floor, and
/// speech is enough windows clearly above that floor and above an absolute
/// minimum, so steady room noise at any level types nothing.
///
/// Every engine is checked, as on Windows: Parakeet runs over the whole
/// recording at once, so a silent press would reach the model with nothing to
/// hear, and Apple may type a stray word over room noise. No speech means an
/// empty result, and an empty result types nothing.
struct SpeechActivity {
    static let windowSeconds = 0.03
    /// Share of windows, quietest first, that marks the noise floor.
    static let floorPercentile = 0.10
    /// A speech window is at least this far above the noise floor. Calibrated
    /// 2026-11-04 on synthetic white, pink, brown and mains-hum noise (Windows
    /// lane): steady noise sat at most 9.0 dB over the floor, speech at 10 dB
    /// signal-to-noise at least 12.5 dB over.
    static let marginDb = 11.0
    /// A speech window is also at least this loud.
    static let minimumDbfs = -60.0
    /// Quieter windows are digital zeros (a muted device or warm-up buffers).
    static let digitalSilenceDbfs = -100.0
    /// Speech needs this many speech windows in total (150 ms at 30 ms windows).
    static let minimumSpeechWindows = 5
    /// The first 90 ms are left out: some devices fade in.
    static let leadWindows = 3

    private let channels: Int
    private let framesPerWindow: Int
    private(set) var windows: [Double] = []
    private var sum = 0.0
    private var channel = 0
    private var frames = 0

    init(sampleRate: Double, channels: Int = 1) {
        self.channels = max(1, channels)
        framesPerWindow = max(1, Int((max(1, sampleRate) * Self.windowSeconds).rounded()))
    }

    /// One interleaved sample, in device channel order. Non-finite samples count as zero.
    mutating func add(_ sample: Float) {
        let value = sample.isFinite ? Double(sample) : 0
        sum += value * value
        channel += 1
        if channel < channels { return }
        channel = 0
        frames += 1
        if frames < framesPerWindow { return }
        windows.append(sum / (Double(framesPerWindow) * Double(channels)))
        sum = 0
        frames = 0
    }

    var windowCount: Int { windows.count }
    var hasSpeech: Bool { Self.decide(windows) }

    static func dbfs(_ meanSquare: Double) -> Double { 10 * log10(max(meanSquare, 1e-14)) }

    /// Mean squares of complete windows in, speech or not out.
    static func decide(_ windowMeanSquares: [Double]) -> Bool {
        var levels = windowMeanSquares.dropFirst(leadWindows).map(dbfs).filter { $0 > digitalSilenceDbfs }
        guard levels.count >= minimumSpeechWindows else { return false }
        levels.sort()
        let floor = levels[Int((floorPercentile * Double(levels.count - 1)).rounded(.down))]
        let threshold = max(floor + marginDb, minimumDbfs)
        return levels.filter { $0 >= threshold }.count >= minimumSpeechWindows
    }

    /// Mono samples at one rate.
    static func detect(_ mono: [Float], sampleRate: Double) -> Bool {
        var activity = SpeechActivity(sampleRate: sampleRate, channels: 1)
        for sample in mono { activity.add(sample) }
        return activity.hasSpeech
    }
}
