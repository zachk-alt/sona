import AVFoundation
import Foundation

// Pure checks of the Parakeet engine slot (scripts/test-speech-engine.sh):
// engine choice, the Apple backup, the pinned model download and its checks,
// the silence check and the config key. No microphone, real speech engine,
// network, window or AI: engines are fakes and downloads are local copies.

var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { print("FAILED: \(message)"); exit(1) }
}

// MARK: - Fakes

final class FakeRecognizer: SampleRecognizer, @unchecked Sendable {
    var ready = true
    var result: Result<String, Error> = .success("parakeet words")
    var delay: Duration = .zero
    /// Blocks without honoring cancellation, as a Core ML call can.
    var stubborn = false
    private(set) var calls = 0
    private(set) var lastSampleCount = 0
    var isReady: Bool { ready }
    func transcribe(_ samples: [Float]) async throws -> String {
        calls += 1
        lastSampleCount = samples.count
        if delay > .zero, stubborn {
            let seconds = Double(delay.components.seconds)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.resume() }
            }
        } else if delay > .zero { try? await Task.sleep(for: delay) }
        return try result.get()
    }
}

struct FakeFailure: Error {}

/// Stands in for AppleTranscriber: counts calls and the frames it was fed.
final class FakeApple: Transcriber {
    var format: AVAudioFormat
    var text = "apple words"
    private(set) var begun = 0, finished = 0, cancelled = 0, prepared = 0
    private(set) var framesFed = 0
    init(format: AVAudioFormat) { self.format = format }
    var requiredFormat: AVAudioFormat? { get async { format } }
    func prepare() async { prepared += 1 }
    func begin() async throws { begun += 1 }
    func feed(_ buffer: AVAudioPCMBuffer) { framesFed += Int(buffer.frameLength) }
    func finish() async throws -> String { finished += 1; return text }
    func cancel() async { cancelled += 1 }
}

let int16Format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

// Seeded noise and speech-like audio, after the Windows lane's test cases.
struct SeededRandom {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
    mutating func gaussian() -> Double { sqrt(-2 * log(1 - next())) * cos(2 * .pi * next()) }
}
var noise = SeededRandom(state: 20261104)
func scale(_ x: [Double], _ dbfs: Double) -> [Float] {
    let rms = sqrt(x.reduce(0) { $0 + $1 * $1 } / Double(max(1, x.count)))
    let gain = pow(10, dbfs / 20) / max(rms, 1e-12)
    return x.map { Float($0 * gain) }
}
func whiteNoise(_ n: Int, _ dbfs: Double) -> [Float] { scale((0..<n).map { _ in noise.gaussian() }, dbfs) }
func pinkNoise(_ n: Int, _ dbfs: Double) -> [Float] {
    // Paul Kellet's economy pink filter: room and fan noise falls with frequency.
    var b0 = 0.0, b1 = 0.0, b2 = 0.0
    var x = [Double](repeating: 0, count: n)
    for i in 0..<n {
        let w = noise.gaussian()
        b0 = 0.99765 * b0 + w * 0.0990460; b1 = 0.96300 * b1 + w * 0.2965164; b2 = 0.57000 * b2 + w * 1.0526913
        x[i] = b0 + b1 + b2 + w * 0.1848
    }
    return scale(x, dbfs)
}
func mix(_ a: [Float], _ b: [Float]) -> [Float] { a.enumerated().map { $0.element + ($0.offset < b.count ? b[$0.offset] : 0) } }
/// Voiced syllables (105 to 135 Hz, formant-weighted harmonics) of 150 to 250 ms, gaps of 60 to 140 ms.
func syllables(_ rate: Int, _ seconds: Double, _ activeDbfs: Double, lead: Double = 0.3) -> [Float] {
    var x = [Double](repeating: 0, count: Int(Double(rate) * seconds))
    var at = Int(Double(rate) * lead)
    var voice = SeededRandom(state: 7)
    var activeSum = 0.0, activeCount = 0
    while at < x.count {
        let length = Int(Double(rate) * (0.15 + 0.1 * voice.next())), end = min(x.count, at + length)
        let pitch = 105 + 30 * voice.next()
        for i in at..<end {
            let t = Double(i - at) / Double(length), envelope = sin(.pi * t)
            var sample = 0.0
            for h in 1...30 {
                let f = pitch * Double(h)
                if f > Double(rate) / 2 { break }
                let formant = exp(-pow((f - 600) / 250, 2)) + 0.6 * exp(-pow((f - 1500) / 300, 2)) + 0.3 * exp(-pow((f - 2600) / 400, 2)) + 0.02
                sample += formant * sin(2 * .pi * f * Double(i) / Double(rate)) / Double(h)
            }
            x[i] = envelope * sample
            activeSum += x[i] * x[i]; activeCount += 1
        }
        at = end + Int(Double(rate) * (0.06 + 0.08 * voice.next()))
    }
    let gain = pow(10, activeDbfs / 20) / max(sqrt(activeSum / Double(max(1, activeCount))), 1e-12)
    return x.map { Float($0 * gain) }
}

// MARK: - Silence check

func testSpeechActivity() {
    let rate = 16000
    let r = Double(rate)
    check(!SpeechActivity.detect([Float](repeating: 0, count: rate * 2), sampleRate: r), "digital silence is not speech")
    for level in [-50.0, -45, -40] {
        for seconds in [1.0, 2.5, 4.0, 30.0] {
            let n = Int(r * seconds)
            check(!SpeechActivity.detect(pinkNoise(n, level), sampleRate: r) && !SpeechActivity.detect(whiteNoise(n, level), sampleRate: r),
                  "room noise at \(level) dBFS for \(seconds) s is not speech")
        }
    }
    var warmUp = [Float](repeating: 0, count: rate * 2)
    let lead = rate * 15 / 100
    let room = pinkNoise(rate * 2 - lead, -45)
    warmUp.replaceSubrange(lead..<(rate * 2), with: room)
    check(!SpeechActivity.detect(warmUp, sampleRate: r), "warm-up zeros before room noise do not lower the floor")
    var fadeIn = pinkNoise(rate, -45)
    for i in 0..<(rate / 10) { fadeIn[i] *= Float(i) / Float(rate / 10) }
    check(!SpeechActivity.detect(fadeIn, sampleRate: r), "a device fade-in before room noise is not speech")
    var click = pinkNoise(rate * 2, -50)
    for i in rate..<(rate + rate * 6 / 100) { click[i] += 0.3 * sin(Float(i)) }
    check(!SpeechActivity.detect(click, sampleRate: r), "one 60 ms click is not speech")
    for level in [-50.0, -45, -40] {
        check(SpeechActivity.detect(mix(syllables(rate, 2, -22), pinkNoise(rate * 2, level)), sampleRate: r),
              "speech over room noise at \(level) dBFS is speech")
    }
    check(SpeechActivity.detect(mix(syllables(rate, 2, -28), pinkNoise(rate * 2, -40)), sampleRate: r),
          "quiet speech 12 dB over -40 dBFS room noise is speech")
    check(SpeechActivity.detect(mix(syllables(rate, 2, -45), pinkNoise(rate * 2, -70)), sampleRate: r),
          "far quiet speech in a quiet room is speech")
    check(SpeechActivity.detect(mix(syllables(rate, 2, -22, lead: 0), pinkNoise(rate * 2, -45)), sampleRate: r),
          "speech that fills the whole recording is speech")
    var word = [Float](repeating: 0, count: rate)
    word.replaceSubrange(0..<Int(r * 0.6), with: syllables(rate, 0.6, -22))
    check(SpeechActivity.detect(mix(word, pinkNoise(rate, -50)), sampleRate: r), "a single short word is speech")
    check(SpeechActivity.detect(mix(syllables(48000, 2, -22), pinkNoise(96000, -45)), sampleRate: 48000), "speech at 48 kHz is speech")
    var withNaN = mix(syllables(rate, 2, -22), pinkNoise(rate * 2, -45))
    withNaN[100] = .nan; withNaN[5000] = .infinity
    check(SpeechActivity.detect(withNaN, sampleRate: r), "non-finite samples count as zero without breaking the check")
    var stereo = SpeechActivity(sampleRate: 48000, channels: 2)
    for _ in 0..<(48000 * 2) { stereo.add(0) }
    check(stereo.windowCount == 33, "30 ms windows count frames, not interleaved samples")
}

// MARK: - Engine choice

func testEngineChoice() {
    check(SpeechEngineSetting(configValue: nil) == .parakeet, "no engine key means Parakeet")
    check(SpeechEngineSetting(configValue: "apple") == .apple, "apple picks Apple")
    check(SpeechEngineSetting(configValue: " Apple ") == .apple, "case and spaces do not matter")
    check(SpeechEngineSetting(configValue: "parakeet") == .parakeet, "parakeet picks Parakeet")
    check(SpeechEngineSetting(configValue: "whisper") == .parakeet, "an unknown engine gets the default")
    check(SpeechEngineSetting(configValue: "") == .parakeet, "an empty engine gets the default")
    check(EnginePolicy.choose(.parakeet, languageSupported: true, parakeetReady: true) == (.parakeet, .parakeet), "a ready Parakeet serves")
    check(EnginePolicy.choose(.parakeet, languageSupported: true, parakeetReady: false) == (.apple, .appleParakeetNotReady), "Apple serves while Parakeet loads")
    check(EnginePolicy.choose(.apple, languageSupported: true, parakeetReady: true) == (.apple, .appleConfigured), "the apple setting always uses Apple")
    check(EnginePolicy.choose(.parakeet, languageSupported: false, parakeetReady: true) == (.apple, .appleLanguage),
          "a language Parakeet cannot serve uses Apple even with Parakeet loaded")
    check(EngineServed.appleLanguage.rawValue == "apple:language", "the language log code")
    for id in ["en_US", "en_GB", "en-AU", "en"] {
        check(EnginePolicy.parakeetSupports(Locale(identifier: id)), "English (\(id)) may use Parakeet")
        check(EnginePolicy.loadsParakeet(.parakeet, locale: Locale(identifier: id)), "English (\(id)) loads Parakeet")
    }
    for id in nonEnglish {
        check(!EnginePolicy.parakeetSupports(Locale(identifier: id)), "\(id) never uses Parakeet")
        check(!EnginePolicy.loadsParakeet(.parakeet, locale: Locale(identifier: id)), "\(id) never downloads or loads Parakeet")
    }
    check(!EnginePolicy.loadsParakeet(.apple, locale: english), "the apple setting never loads Parakeet")
    check(EnginePolicy.parakeetLimit(audioSeconds: 5, cap: 10) == 3, "short recordings get the 3 s floor")
    check(EnginePolicy.parakeetLimit(audioSeconds: 240, cap: 10) == 6, "four minutes get 6 s")
    check(EnginePolicy.parakeetLimit(audioSeconds: 3600, cap: 10) == 10, "the Parakeet limit never passes its cap")
    check(AppStateDeadlinesStandIn.parakeetCap < AppStateDeadlinesStandIn.transcribing, "Apple keeps time inside the transcribing deadline")
}

/// Mirrors AppState.Deadlines defaults (AppState is not compiled here). The
/// session recovery tests compile the real struct; this keeps the ordering honest.
enum AppStateDeadlinesStandIn {
    static let parakeetCap: TimeInterval = 10
    static let transcribing: TimeInterval = 15
}

let english = Locale(identifier: "en_US")
/// Chinese, Japanese and Korean are outside Parakeet Ultra; the European ones
/// were never tested, so Apple keeps them too.
let nonEnglish = ["ja_JP", "zh-Hans_CN", "zh-Hant_TW", "ko_KR", "de_DE", "fr_FR", "es_ES"]

func speechSamples(seconds: Double) -> [Float] {
    mix(syllables(16000, seconds, -22), pinkNoise(Int(16000 * seconds), -50))
}

func pcm(_ samples: [Float]) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: DictationTranscriber.parakeetFormat, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    return buffer
}

func testFallback() async {
    var logs: [String] = []
    // Parakeet ready: it serves, buffers in 16 kHz mono Float32, Apple untouched.
    do {
        let parakeet = FakeRecognizer()
        var apples: [FakeApple] = []
        let t = DictationTranscriber(setting: .parakeet, locale: english, parakeet: parakeet,
                                     makeApple: { let a = FakeApple(format: int16Format); apples.append(a); return a },
                                     parakeetCap: 10, log: { logs.append($0) })
        try! await t.begin()
        let format = await t.requiredFormat
        check(format?.sampleRate == 16000 && format?.channelCount == 1 && format?.commonFormat == .pcmFormatFloat32,
              "Parakeet asks for 16 kHz mono Float32")
        let samples = speechSamples(seconds: 2)
        t.feed(pcm(Array(samples[0..<16000]))); t.feed(pcm(Array(samples[16000...])))
        let text = try! await t.finish()
        check(text == "parakeet words" && t.lastServed == .parakeet, "a ready Parakeet transcribes the session")
        check(parakeet.lastSampleCount == samples.count, "every fed sample reaches Parakeet")
        check(apples.count == 1 && apples[0].begun == 0, "Apple is not opened while Parakeet serves")
        check(logs.last?.contains("served=parakeet") == true && !logs.joined().contains("parakeet words"),
              "the log names the engine and never the text")
    }
    // Silence: nothing is transcribed and nothing is typed.
    do {
        let parakeet = FakeRecognizer()
        let t = DictationTranscriber(setting: .parakeet, locale: english, parakeet: parakeet,
                                     makeApple: { FakeApple(format: int16Format) }, parakeetCap: 10, log: { _ in })
        try! await t.begin()
        t.feed(pcm(pinkNoise(16000 * 3, -45)))
        let text = try! await t.finish()
        check(text.isEmpty && parakeet.calls == 0 && t.lastServed == .silence, "room noise alone types nothing and skips the engine")
    }
    // Parakeet not ready: Apple serves live.
    do {
        let parakeet = FakeRecognizer(); parakeet.ready = false
        var apples: [FakeApple] = []
        let t = DictationTranscriber(setting: .parakeet, locale: english, parakeet: parakeet,
                                     makeApple: { let a = FakeApple(format: int16Format); apples.append(a); return a },
                                     parakeetCap: 10, log: { _ in })
        try! await t.begin()
        check(await t.requiredFormat == int16Format, "Apple's own format while Apple serves")
        t.feed(pcm(speechSamples(seconds: 1)))
        let text = try! await t.finish()
        check(text == "apple words" && t.lastServed == .appleParakeetNotReady && parakeet.calls == 0,
              "Apple serves a press that comes before Parakeet is ready")
        check(apples[0].begun == 1 && apples[0].framesFed == 16000, "Apple gets the live audio")
    }
    // Not English: Apple serves every session, even with Parakeet loaded.
    for id in nonEnglish {
        let parakeet = FakeRecognizer()
        var apples: [FakeApple] = []
        logs = []
        let t = DictationTranscriber(setting: .parakeet, locale: Locale(identifier: id), parakeet: parakeet,
                                     makeApple: { let a = FakeApple(format: int16Format); apples.append(a); return a },
                                     parakeetCap: 10, log: { logs.append($0) })
        for _ in 1...2 {
            try! await t.begin()
            check(await t.requiredFormat == int16Format, "\(id): Apple's own format")
            t.feed(pcm(speechSamples(seconds: 1)))
            let text = try! await t.finish()
            check(text == "apple words" && t.lastServed == .appleLanguage, "\(id): Apple transcribes the session")
        }
        check(parakeet.calls == 0, "\(id): Parakeet is never called")
        check(apples.count == 1 && apples[0].begun == 2 && apples[0].framesFed == 32000, "\(id): Apple gets the live audio")
        check(logs.allSatisfy { $0.contains("served=apple:language") } && !logs.joined().contains("apple words"),
              "\(id): the log names the reason and never the text")
    }
    // Config says apple: Parakeet is never used.
    do {
        let parakeet = FakeRecognizer()
        let t = DictationTranscriber(setting: .apple, locale: english, parakeet: parakeet,
                                     makeApple: { FakeApple(format: int16Format) }, parakeetCap: 10, log: { _ in })
        try! await t.begin()
        t.feed(pcm(speechSamples(seconds: 1)))
        _ = try! await t.finish()
        check(t.lastServed == .appleConfigured && parakeet.calls == 0, "the apple setting never calls Parakeet")
    }
    // Parakeet throws: a fresh Apple engine transcribes the same samples.
    do {
        let parakeet = FakeRecognizer(); parakeet.result = .failure(FakeFailure())
        var apples: [FakeApple] = []
        logs = []
        let t = DictationTranscriber(setting: .parakeet, locale: english, parakeet: parakeet,
                                     makeApple: { let a = FakeApple(format: int16Format); apples.append(a); return a },
                                     parakeetCap: 10, log: { logs.append($0) })
        try! await t.begin()
        t.feed(pcm(speechSamples(seconds: 3)))
        let text = try! await t.finish()
        check(text == "apple words" && t.lastServed == .appleParakeetFailed, "Apple transcribes when Parakeet throws")
        check(apples.count == 2 && apples[0].begun == 0, "the backup is a fresh Apple engine, not the live one")
        let fed = apples[1].framesFed
        check(apples[1].begun == 1 && apples[1].finished == 1 && abs(fed - 48000) <= 64,
              "the backup hears the same 3 s of audio, converted to its format (\(fed) frames)")
        check(logs.contains { $0.contains("served=apple:parakeet-failed") }, "the log names the backup and why")
    }
    // Parakeet stalls: the bound fires and Apple takes over.
    do {
        let parakeet = FakeRecognizer(); parakeet.delay = .seconds(8); parakeet.stubborn = true
        var apples: [FakeApple] = []
        let t = DictationTranscriber(setting: .parakeet, locale: english, parakeet: parakeet,
                                     makeApple: { let a = FakeApple(format: int16Format); apples.append(a); return a },
                                     parakeetCap: 0.2, log: { _ in })
        try! await t.begin()
        t.feed(pcm(speechSamples(seconds: 1)))
        let clock = ContinuousClock(); let start = clock.now
        let text = try! await t.finish()
        let took = clock.now - start
        check(text == "apple words" && t.lastServed == .appleParakeetFailed, "a stalled Parakeet hands over to Apple")
        check(took < .seconds(4), "the Parakeet attempt is bounded (took \(took))")
    }
    // Same format as Parakeet's: the backup gets the samples unconverted.
    do {
        let samples = speechSamples(seconds: 1.3)
        let chunks = try! DictationTranscriber.convert(samples, to: DictationTranscriber.parakeetFormat)
        check(chunks.reduce(0) { $0 + Int($1.frameLength) } == samples.count, "no conversion keeps every sample")
        let resampled = try! DictationTranscriber.convert(samples, to: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!)
        let frames = resampled.reduce(0) { $0 + Int($1.frameLength) }
        check(abs(frames - samples.count * 3) <= 192, "converting to 48 kHz keeps the length (\(frames))")
    }
}

// MARK: - Silence check on the Apple path

/// `samples` (mono, -1...1) in `format`, every channel carrying the same signal.
func pcm(_ samples: [Float], as format: AVAudioFormat) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let channels = Int(format.channelCount), interleaved = format.isInterleaved
    for channel in 0..<channels {
        for (frame, sample) in samples.enumerated() {
            let index = interleaved ? frame * channels + channel : frame
            if format.commonFormat == .pcmFormatInt16 {
                buffer.int16ChannelData![interleaved ? 0 : channel][index] = Int16(max(-32768, min(32767, (sample * 32768).rounded())))
            } else if format.commonFormat == .pcmFormatFloat64 {
                // AVAudioPCMBuffer has no Float64 accessor; the raw list does.
                let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                list[interleaved ? 0 : channel].mData!.assumingMemoryBound(to: Double.self)[index] = Double(sample)
            } else {
                buffer.floatChannelData![interleaved ? 0 : channel][index] = sample
            }
        }
    }
    return buffer
}

func resample(_ samples: [Float], by factor: Int) -> [Float] { samples.flatMap { Array(repeating: $0, count: factor) } }

func testAppleSilence() async {
    let quietRoom = pinkNoise(16000 * 2, -70)
    let formats: [(String, AVAudioFormat)] = [
        ("16 kHz Float32", DictationTranscriber.parakeetFormat),
        ("16 kHz Int16", int16Format),
        ("48 kHz Float32", AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!),
        ("44.1 kHz Int16", AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true)!),
        ("48 kHz stereo Int16", AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true)!),
    ]
    for (name, format) in formats {
        let factor = format.sampleRate == 16000 ? 1 : 3
        let rate = Double(format.sampleRate)
        // 44.1 kHz gets 48 kHz audio played slower: the windows follow the buffer's own rate.
        let silent = resample(quietRoom, by: factor), speech = resample(speechSamples(seconds: 2), by: factor)
        for setting in [SpeechEngineSetting.apple, .parakeet] {
            var apples: [FakeApple] = []
            var logs: [String] = []
            let parakeet = FakeRecognizer(); parakeet.ready = setting == .apple
            let t = DictationTranscriber(setting: setting, locale: english, parakeet: parakeet,
                                         makeApple: { let a = FakeApple(format: format); a.text = "okay"; apples.append(a); return a },
                                         parakeetCap: 10, log: { logs.append($0) })
            try! await t.begin()
            t.feed(pcm(Array(silent[..<(silent.count / 2)]), as: format)); t.feed(pcm(Array(silent[(silent.count / 2)...]), as: format))
            let text = try! await t.finish()
            check(text.isEmpty && t.lastServed == .silence, "\(name), \(setting): a quiet room on Apple types nothing (got \(text.count) chars)")
            check(apples[0].finished == 0 && apples[0].cancelled == 1, "\(name), \(setting): Apple is cancelled, not finished, on no speech")
            let seconds = String(format: "audio_s=%.1f", Double(silent.count) / rate)
            check(logs.count == 1 && logs[0].hasPrefix("engine: served=none:no-speech \(seconds) finish_ms=") && logs[0].hasSuffix(" chars=0"),
                  "\(name), \(setting): the log line matches the Parakeet path: \(logs)")
            try! await t.begin()
            t.feed(pcm(speech, as: format))
            let heard = try! await t.finish()
            check(heard == "okay" && t.lastServed != .silence && apples[0].finished == 1,
                  "\(name), \(setting): speech still reaches Apple and is typed")
            check(parakeet.calls == 0, "\(name), \(setting): Parakeet is not called")
        }
    }
    // A press with no audio at all is no speech, as on the Parakeet path.
    do {
        let apple = FakeApple(format: int16Format)
        let t = DictationTranscriber(setting: .apple, locale: english, parakeet: nil, makeApple: { apple },
                                     parakeetCap: 10, log: { _ in })
        try! await t.begin()
        let text = try! await t.finish()
        check(text.isEmpty && t.lastServed == .silence && apple.cancelled == 1, "no audio at all types nothing")
    }
    // Audio the check cannot read never blocks Apple.
    do {
        let float64 = AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: 16000, channels: 1, interleaved: false)!
        let apple = FakeApple(format: float64)
        let t = DictationTranscriber(setting: .apple, locale: english, parakeet: nil, makeApple: { apple },
                                     parakeetCap: 10, log: { _ in })
        try! await t.begin()
        t.feed(pcm(quietRoom, as: float64))
        let text = try! await t.finish()
        check(text == "apple words" && t.lastServed == .appleConfigured, "an unread sample format leaves the session to Apple")
    }
    // A cancelled session leaves nothing for the next one.
    do {
        let apple = FakeApple(format: int16Format)
        let t = DictationTranscriber(setting: .apple, locale: english, parakeet: nil, makeApple: { apple },
                                     parakeetCap: 10, log: { _ in })
        try! await t.begin()
        t.feed(pcm(speechSamples(seconds: 2), as: int16Format))
        await t.cancel()
        try! await t.begin()
        t.feed(pcm(quietRoom, as: int16Format))
        let text = try! await t.finish()
        check(text.isEmpty && t.lastServed == .silence, "speech from a cancelled session does not count toward the next")
    }
    // PCMSamples reads every layout the same way.
    let stereo = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 2, interleaved: true)!
    let two = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 2)!
    two.frameLength = 2
    two.int16ChannelData![0][0] = 16384; two.int16ChannelData![0][1] = -16384
    two.int16ChannelData![0][2] = 8192; two.int16ChannelData![0][3] = 0
    check(PCMSamples.interleaved(two) == [0.5, -0.5, 0.25, 0], "interleaved Int16 reads in frame and channel order")
    let mono = PCMSamples.mono(two, into: DictationTranscriber.parakeetFormat)
    check(mono.map { Array(UnsafeBufferPointer(start: $0.floatChannelData![0], count: Int($0.frameLength))) } == [0, 0.125],
          "the mono mix averages every channel")
}

// MARK: - Pinned model download

func testModelStore() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("sona-model-tests-\(UUID().uuidString)")
    let origin = root.appendingPathComponent("origin")
    defer { try? manager.removeItem(at: root) }
    try manager.createDirectory(at: origin.appendingPathComponent("Model.mlmodelc/weights"), withIntermediateDirectories: true)
    let weights = Data((0..<5000).map { UInt8($0 % 251) })
    let vocab = Data("{\"0\":\"a\"}".utf8)
    try weights.write(to: origin.appendingPathComponent("Model.mlmodelc/weights/weight.bin"))
    try vocab.write(to: origin.appendingPathComponent("vocab.json"))
    // Expected hashes come from /usr/bin/shasum, independent of ModelStore.verify.
    let hex = sha256Hex
    let good = ModelManifest(name: "test-model", repository: "Example/test-model", commit: "abc123", files: [
        ModelFile(path: "Model.mlmodelc/weights/weight.bin", size: Int64(weights.count), sha256: hex(weights)),
        ModelFile(path: "vocab.json", size: Int64(vocab.count), sha256: hex(vocab)),
    ])
    check(good.url(for: good.files[0]).absoluteString == "https://huggingface.co/Example/test-model/resolve/abc123/Model.mlmodelc/weights/weight.bin",
          "files download from the pinned commit, never main")
    check(ModelManifest.parakeetUltra.url(for: ModelManifest.parakeetUltra.files[0]).absoluteString.hasPrefix(
        "https://huggingface.co/FluidInference/parakeet-ultra-coreml/resolve/95eaa59a39d4394f047a4dc5cce480388a60d1b6/"),
          "Parakeet Ultra is pinned to its audited commit")
    check(ModelManifest.parakeetUltra.files.count == 20 && ModelManifest.parakeetUltra.files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 },
          "every Parakeet file has a size and a SHA-256")

    var fetches: [String] = []
    /// Copies from the origin folder, optionally corrupting what it hands back.
    func copier(_ corrupt: ((inout Data) -> Void)? = nil) -> (URL) async throws -> URL {
        return { url in
            let path = url.absoluteString.components(separatedBy: "/resolve/abc123/")[1]
            fetches.append(path)
            var data = try Data(contentsOf: origin.appendingPathComponent(path))
            corrupt?(&data)
            let out = manager.temporaryDirectory.appendingPathComponent("sona-fetch-\(UUID().uuidString)")
            try data.write(to: out)
            return out
        }
    }
    func leftovers(_ store: ModelStore) -> [String] {
        let all = (manager.enumerator(atPath: store.directory.path)?.allObjects as? [String]) ?? []
        return all.filter { $0.contains(".partial") }
    }

    // Good files download, check and land in <root>/<name>/<commit>.
    let models = root.appendingPathComponent("Models")
    var store = ModelStore(manifest: good, root: models, fetch: copier())
    let first = try await store.ensure()
    check(first.downloaded == 2 && !first.cheap, "a fresh install downloads every file")
    check(store.directory.path.hasSuffix("Models/test-model/abc123"), "the model folder is named by its commit")
    check(manager.contents(atPath: store.directory.appendingPathComponent("vocab.json").path) == vocab, "files land under their real names")
    check(leftovers(store).isEmpty, "no temporary file is left after a good download")
    check(store.isReadyCheap(), "a full check stamps the folder")
    fetches = []
    let second = try await store.ensure()
    check(second.cheap && fetches.isEmpty, "the next launch trusts sizes plus the stamp and downloads nothing")

    // A file changed on disk with the same size: the stamp is dropped by hand
    // (as a failed load would) and the full check finds and replaces it.
    var tampered = weights; tampered[10] ^= 0xFF
    try tampered.write(to: store.directory.appendingPathComponent("Model.mlmodelc/weights/weight.bin"))
    try manager.removeItem(at: store.directory.appendingPathComponent(ModelStore.stampName))
    fetches = []
    let repaired = try await store.ensure()
    check(repaired.downloaded == 1 && repaired.verified == 1 && fetches == ["Model.mlmodelc/weights/weight.bin"],
          "only the wrong file downloads again")

    // Wrong size from the server: refused, nothing left in place.
    let fresh = root.appendingPathComponent("Models2")
    store = ModelStore(manifest: good, root: fresh, fetch: copier { $0.append(0) })
    do { try await store.ensure(); check(false, "a wrong-size download must fail") }
    catch let error as ModelStoreError { check(error == .badSize("Model.mlmodelc/weights/weight.bin"), "a wrong size is refused: \(error)") }
    check(!manager.fileExists(atPath: store.directory.appendingPathComponent("Model.mlmodelc/weights/weight.bin").path),
          "a wrong-size file never takes the real name")
    check(leftovers(store).isEmpty && !store.isReadyCheap(), "no temporary file and no stamp after a wrong size")

    // Wrong hash, right size: refused, nothing left in place.
    store = ModelStore(manifest: good, root: root.appendingPathComponent("Models3"), fetch: copier { $0[0] ^= 0x01 })
    do { try await store.ensure(); check(false, "a wrong-hash download must fail") }
    catch let error as ModelStoreError { check(error == .badHash("Model.mlmodelc/weights/weight.bin"), "a wrong hash is refused: \(error)") }
    check(!manager.fileExists(atPath: store.directory.appendingPathComponent("Model.mlmodelc/weights/weight.bin").path),
          "a wrong-hash file never takes the real name")
    check(leftovers(store).isEmpty && !store.isReadyCheap(), "no temporary file and no stamp after a wrong hash")

    // Missing on the server: the error passes through, nothing stamped.
    store = ModelStore(manifest: good, root: root.appendingPathComponent("Models4"), fetch: { _ in throw URLError(.fileDoesNotExist) })
    do { try await store.ensure(); check(false, "a missing download must fail") } catch { check(error is URLError, "a missing file fails the install") }
    check(!store.isReadyCheap(), "nothing is stamped when a file is missing")

    // A missing file on disk is caught by the cheap check and by verify.
    store = ModelStore(manifest: good, root: models, fetch: copier())
    try manager.removeItem(at: store.directory.appendingPathComponent("vocab.json"))
    check(!store.isReadyCheap(), "a deleted file fails the cheap check")
    do { try ModelStore.verify(store.directory.appendingPathComponent("vocab.json"), good.files[1]); check(false, "verify must fail") }
    catch let error as ModelStoreError { check(error == .missing("vocab.json"), "verify reports a missing file") }
    let restored = try await store.ensure()
    check(restored.downloaded == 1 && store.isReadyCheap(), "a missing file is downloaded again and restamped")

    // A temporary file left by a quit mid-download is removed on the next check.
    let stale = store.directory.appendingPathComponent("Model.mlmodelc/weights/.weight.bin.0000.partial")
    try Data([1, 2, 3]).write(to: stale)
    try manager.removeItem(at: store.directory.appendingPathComponent(ModelStore.stampName))
    _ = try await store.ensure()
    check(!manager.fileExists(atPath: stale.path) && leftovers(store).isEmpty && store.isReadyCheap(),
          "a leftover temporary file from an interrupted download is cleaned up")

    // A path that tries to leave the folder is refused.
    let escape = ModelManifest(name: "x", repository: "x/x", commit: "c", files: [ModelFile(path: "../evil", size: 1, sha256: "")])
    do { _ = try ModelStore(manifest: escape, root: root, fetch: copier()).fileURL(escape.files[0]); check(false, "escape must fail") }
    catch let error as ModelStoreError { check(error == .unsafePath("../evil"), "a path outside the model folder is refused") }
}

func sha256Hex(_ data: Data) -> String {
    // /usr/bin/shasum gives a value independent of the CryptoKit code under test.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sona-hash-\(UUID().uuidString)")
    try! data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try! process.run()
    process.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return String(out.prefix(64))
}

// MARK: - Config key

func testConfig() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sona-engine-config-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("config.json")
    func decode(_ json: String) -> Config { try! JSONDecoder().decode(Config.self, from: Data(json.utf8)) }
    check(decode("{}").speechEngine == .parakeet, "no engine key decodes to Parakeet")
    check(decode(#"{"engine":"apple"}"#).speechEngine == .apple, "engine apple decodes")
    check(decode(#"{"engine":"parakeet"}"#).speechEngine == .parakeet, "engine parakeet decodes")
    check(decode(#"{"engine":"whisper"}"#).speechEngine == .parakeet, "an unknown engine decodes to the default")
    let typed = decode(#"{"engine":5,"hotkey":"f8"}"#)
    check(typed.speechEngine == .parakeet && typed.hotkey == "f8", "a non-string engine never fails the rest of the file")
    for value in ["apple", "whisper"] {
        try! Data(#"{"engine":"\#(value)","hotkey":"right-command"}"#.utf8).write(to: url)
        var config = Config.load(from: url)
        config.hotkey = "f8"
        check(config.save(to: url) == nil, "save succeeds")
        let object = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        check(object["engine"] as? String == value && object["hotkey"] as? String == "f8",
              "save keeps the user's engine value \(value) exactly")
        check(Config.load(from: url).engine == value, "the saved engine reads back")
    }
    try! Data(#"{"hotkey":"right-command"}"#.utf8).write(to: url)
    var config = Config.load(from: url); config.hotkey = "f8"
    _ = config.save(to: url)
    let object = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    check(object["engine"] == nil, "save never adds an engine key the user did not write")
}

// MARK: - Credits (CC BY 4.0 model, Apache-2.0 engine)

func testCredits() {
    let text = ThirdPartyCredits.text
    for required in ["moondream", "NVIDIA", "FluidInference", "https://creativecommons.org/licenses/by/4.0/",
                     "converted copy", "not under Sona's license", "FluidAudio", "Apache License 2.0"] {
        check(text.contains(required), "the About credits name \(required)")
    }
    check(!text.contains("\u{2014}") && !text.contains("\u{2013}"), "no em or en dashes in the credits")
    let notices = (try? String(contentsOfFile: "docs/THIRD-PARTY-MAC.md", encoding: .utf8)) ?? ""
    check(notices.contains(ModelManifest.parakeetUltra.commit) && notices.contains("0.18.2"),
          "the notices file names the pinned model commit and engine version")
    check(ModelManifest.parakeetUltra.totalBytes == 632_314_500 && notices.contains("632,314,500"),
          "the notices file states the manifest's byte total")
}

@main
struct SpeechEngineMain {
    static func main() async {
        testSpeechActivity()
        testEngineChoice()
        await testFallback()
        await testAppleSilence()
        do { try await testModelStore() } catch { check(false, "model store threw \(error)") }
        testConfig()
        testCredits()
        print("Speech engine checks passed (\(checks)).")
    }
}
