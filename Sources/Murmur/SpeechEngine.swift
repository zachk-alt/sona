import AVFoundation
import Foundation

/// Which speech engine the config asks for: "engine": "parakeet" (default) or "apple".
enum SpeechEngineSetting: String {
    case parakeet, apple

    /// Absent, misspelled or unknown values get the default.
    init(configValue: String?) {
        let value = configValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = SpeechEngineSetting(rawValue: value) ?? .parakeet
    }
}

extension Config {
    var speechEngine: SpeechEngineSetting { SpeechEngineSetting(configValue: engine) }
}

/// Which engine served a session and why, as a fixed code for the log.
enum EngineServed: String {
    /// Parakeet transcribed the session.
    case parakeet = "parakeet"
    /// The config chose Apple.
    case appleConfigured = "apple:configured"
    /// The user's language is not English, so Apple serves and Parakeet is
    /// never downloaded or loaded.
    case appleLanguage = "apple:language"
    /// Parakeet was still downloading, checking or loading at the key press.
    case appleParakeetNotReady = "apple:parakeet-not-ready"
    /// Parakeet threw or overran at finish; Apple transcribed the same audio.
    case appleParakeetFailed = "apple:parakeet-failed"
    /// The silence check found no speech, so nothing was transcribed.
    case silence = "none:no-speech"
}

/// The pure decisions, kept apart from the engines so the harness can test them.
enum EnginePolicy {
    enum Live: Equatable { case parakeet, apple }

    /// Parakeet Ultra covers European languages only (no Chinese, Japanese or
    /// Korean) and the accuracy audit tested English only, so it serves
    /// English alone. Other languages keep Apple, which follows the same
    /// locale. Windows makes the same split (Parakeet for English, else Whisper).
    static func parakeetSupports(_ locale: Locale) -> Bool {
        locale.language.languageCode == .english
    }

    /// At launch: download, check and load Parakeet only when it could serve.
    static func loadsParakeet(_ setting: SpeechEngineSetting, locale: Locale) -> Bool {
        setting == .parakeet && parakeetSupports(locale)
    }

    /// At the key press: Parakeet only when chosen, able to serve the user's
    /// language and loaded.
    static func choose(_ setting: SpeechEngineSetting, languageSupported: Bool,
                       parakeetReady: Bool) -> (Live, EngineServed) {
        switch setting {
        case .apple: return (.apple, .appleConfigured)
        case .parakeet:
            guard languageSupported else { return (.apple, .appleLanguage) }
            return parakeetReady ? (.parakeet, .parakeet) : (.apple, .appleParakeetNotReady)
        }
    }

    /// How long Parakeet may take at finish before Apple gets the same audio.
    /// Parakeet ran about 90 times faster than real time in the audit, so a
    /// ten-minute dictation needs about 7 s; the cap leaves Apple room inside
    /// AppState.Deadlines.transcribing.
    static func parakeetLimit(audioSeconds: Double, cap: TimeInterval) -> TimeInterval {
        min(cap, max(3, 2 + audioSeconds / 60))
    }
}

/// Whole-utterance speech recognition over 16 kHz mono samples.
protocol SampleRecognizer: AnyObject, Sendable {
    /// Loaded and not busy with an earlier, overrun session.
    var isReady: Bool { get }
    func transcribe(_ samples: [Float]) async throws -> String
}

enum SpeechEngineError: Error { case timedOut, noAudioFormat }

/// Lets exactly one of several racers resume a continuation.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// Collects one session's samples from the audio thread.
final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func reset() { lock.lock(); samples = []; lock.unlock() }

    /// Mono Float32 buffers only (AudioCapture converts to requiredFormat).
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        lock.unlock()
    }

    func append(_ more: [Float]) { lock.lock(); samples.append(contentsOf: more); lock.unlock() }

    func take() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }
}

/// Runs the silence check over one session's buffers as they reach Apple's
/// engine, from the audio thread. Apple takes its own format (16-bit on some
/// Macs, not always 16 kHz), so samples are read as Float and the windows
/// follow the buffer's own rate and channel count.
final class SpeechActivityMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var activity: SpeechActivity?
    private var rate = 0.0
    private var channels: AVAudioChannelCount = 0
    private var frames = 0
    /// Audio this cannot judge (an unread sample format or a format change
    /// mid-session). The check then never blocks the session.
    private var unjudged = false

    func reset() {
        lock.withLock { activity = nil; rate = 0; channels = 0; frames = 0; unjudged = false }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let format = buffer.format
        let samples = PCMSamples.interleaved(buffer)
        lock.withLock {
            guard !unjudged, let samples else { unjudged = true; return }
            if activity == nil {
                activity = SpeechActivity(sampleRate: format.sampleRate, channels: Int(format.channelCount))
                rate = format.sampleRate
                channels = format.channelCount
            }
            guard format.sampleRate == rate, format.channelCount == channels else { unjudged = true; return }
            for sample in samples { activity!.add(sample) }
            frames += Int(buffer.frameLength)
        }
    }

    /// Whether the session held speech, and its length. Takes the result and
    /// starts over. No audio at all is no speech, as on the Parakeet path.
    func take() -> (hasSpeech: Bool, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        let result = (unjudged || activity?.hasSpeech == true, rate > 0 ? Double(frames) / rate : 0)
        activity = nil; rate = 0; channels = 0; frames = 0; unjudged = false
        return result
    }
}

/// The app's speech engine slot: Parakeet when chosen, ready and the user's
/// language is English, Apple otherwise, and Apple again over the same audio
/// if Parakeet fails.
///
/// Parakeet hears the whole recording at once after the key comes up, so
/// this buffers 16 kHz mono samples while recording. The silence check runs
/// first on every engine; no speech returns an empty result and nothing is
/// typed. Apple streams live, so its audio is measured as it is fed and a
/// silent session is cancelled instead of finished, as Windows does.
final class DictationTranscriber: Transcriber {
    static let sampleRate = 16000.0
    static let parakeetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                              channels: 1, interleaved: false)!

    private let setting: SpeechEngineSetting
    /// Whether Parakeet can serve the user's language (fixed at creation).
    private let languageSupported: Bool
    private let parakeet: SampleRecognizer?
    private let apple: Transcriber
    private let makeApple: () -> Transcriber
    private let parakeetCap: TimeInterval
    private let buffer = SampleBuffer()
    private let meter = SpeechActivityMeter()
    private var live: EnginePolicy.Live = .apple
    private var reason: EngineServed = .appleConfigured
    private let log: (String) -> Void
    /// Last session's engine code, for the self-test.
    private(set) var lastServed: EngineServed?

    /// - Parameter locale: the user's locale, the same one Apple's engine
    ///   follows; anything but English keeps every session on Apple.
    init(setting: SpeechEngineSetting, locale: Locale, parakeet: SampleRecognizer?,
         makeApple: @escaping () -> Transcriber, parakeetCap: TimeInterval,
         log: @escaping (String) -> Void = { Log.write($0) }) {
        self.setting = setting
        languageSupported = EnginePolicy.parakeetSupports(locale)
        self.parakeet = parakeet
        self.makeApple = makeApple
        apple = makeApple()
        self.parakeetCap = parakeetCap
        self.log = log
    }

    var requiredFormat: AVAudioFormat? {
        get async { live == .parakeet ? Self.parakeetFormat : await apple.requiredFormat }
    }

    /// Warms Apple only: Apple serves until Parakeet has loaded, and the
    /// first key press waits for this. Parakeet loads on its own task.
    func prepare() async { await apple.prepare() }

    func begin() async throws {
        (live, reason) = EnginePolicy.choose(setting, languageSupported: languageSupported,
                                             parakeetReady: parakeet?.isReady == true)
        if live == .parakeet {
            buffer.reset()
        } else {
            meter.reset()
            try await apple.begin()
        }
    }

    func feed(_ pcm: AVAudioPCMBuffer) {
        if live == .parakeet {
            buffer.append(pcm)
        } else {
            meter.append(pcm)
            apple.feed(pcm)
        }
    }

    func finish() async throws -> String {
        let clock = ContinuousClock()
        let start = clock.now
        func done(_ served: EngineServed, _ text: String, audio: Double?) -> String {
            lastServed = served
            let seconds = audio.map { String(format: " audio_s=%.1f", $0) } ?? ""
            log("engine: served=\(served.rawValue)\(seconds) finish_ms=\(Self.ms(clock.now - start)) chars=\(text.count)")
            return text
        }
        guard live == .parakeet, let parakeet else {
            // Apple may type a stray word over room noise; no speech skips it.
            let heard = meter.take()
            guard heard.hasSpeech else {
                await apple.cancel()
                return done(.silence, "", audio: heard.seconds)
            }
            let text = try await apple.finish()
            return done(reason, text, audio: nil)
        }
        let samples = buffer.take()
        let seconds = Double(samples.count) / Self.sampleRate
        guard SpeechActivity.detect(samples, sampleRate: Self.sampleRate) else {
            return done(.silence, "", audio: seconds)
        }
        do {
            let limit = EnginePolicy.parakeetLimit(audioSeconds: seconds, cap: parakeetCap)
            let text = try await Self.bounded(limit) { try await parakeet.transcribe(samples) }
            return done(.parakeet, text.trimmingCharacters(in: .whitespacesAndNewlines), audio: seconds)
        } catch {
            // The error's type only: never its text, which could quote audio.
            log("engine: parakeet failed (\(type(of: error))); Apple transcribes the same audio")
            let text = try await Self.replay(samples, into: makeApple())
            return done(.appleParakeetFailed, text, audio: seconds)
        }
    }

    func cancel() async {
        buffer.reset()
        meter.reset()
        if live == .apple { await apple.cancel() }
    }

    /// Runs `work`, or throws timedOut after `seconds`, whichever is first.
    /// Not a task group: a group waits for every child, and a Core ML call
    /// that ignores cancellation would hold it past the limit. The overrun
    /// work keeps running detached; a recognizer stays busy (not ready) until
    /// it really returns, so the next session uses Apple instead of queueing.
    static func bounded<T: Sendable>(_ seconds: TimeInterval,
                                     _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let worker = Task {
                do {
                    let value = try await work()
                    if once.claim() { continuation.resume(returning: value) }
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                if once.claim() {
                    worker.cancel()
                    continuation.resume(throwing: SpeechEngineError.timedOut)
                }
            }
        }
    }

    /// Feeds recorded samples to a fresh Apple engine as fast as it takes them.
    static func replay(_ samples: [Float], into transcriber: Transcriber) async throws -> String {
        try await transcriber.begin()
        guard let format = await transcriber.requiredFormat else {
            await transcriber.cancel()
            throw SpeechEngineError.noAudioFormat
        }
        do {
            for chunk in try convert(samples, to: format) { transcriber.feed(chunk) }
        } catch {
            await transcriber.cancel()
            throw error
        }
        return try await transcriber.finish()
    }

    /// 16 kHz mono Float32 samples to buffers in `format`, 0.5 s at a time.
    /// AVAudioConverter can raise Objective-C exceptions.
    static func convert(_ samples: [Float], to format: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        let chunkFrames = Int(sampleRate / 2)
        var input: [AVAudioPCMBuffer] = []
        var index = 0
        while index < samples.count {
            let count = min(chunkFrames, samples.count - index)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: parakeetFormat, frameCapacity: AVAudioFrameCount(count)) else { break }
            pcm.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                pcm.floatChannelData![0].update(from: source.baseAddress! + index, count: count)
            }
            input.append(pcm)
            index += count
        }
        if format == parakeetFormat { return input }
        return try catchingFrameworkException {
            guard let converter = AVAudioConverter(from: parakeetFormat, to: format) else {
                throw SpeechEngineError.noAudioFormat
            }
            var output: [AVAudioPCMBuffer] = []
            var pending = input[...]
            var ended = false
            let ratio = format.sampleRate / sampleRate
            while true {
                let capacity = AVAudioFrameCount(Double(chunkFrames) * ratio) + 1024
                guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { break }
                var error: NSError?
                let status = converter.convert(to: out, error: &error) { _, inputStatus in
                    if let next = pending.first {
                        pending = pending.dropFirst()
                        inputStatus.pointee = .haveData
                        return next
                    }
                    ended = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if let error { throw error }
                if out.frameLength > 0 { output.append(out) }
                if status == .endOfStream || status == .error || (ended && out.frameLength == 0) { break }
            }
            return output
        }
    }

    private static func ms(_ duration: Duration) -> Int {
        Int((Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15).rounded())
    }
}
