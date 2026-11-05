import AVFoundation
import Foundation

// Pure checks of the dictation pipeline pieces that need no microphone, no
// speech engine and no window (scripts/test-dictation-pipeline.sh): how a
// session's results become its text, the sample-rate converter's settings and
// its end-of-recording flush, and the text-free session diagnostics.

var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { print("FAILED: \(message)"); exit(1) }
}

// MARK: - Never-final text (M5)

func testTranscriptAssembler() {
    // The normal shape: volatile guesses, each replaced by a final result.
    do {
        var a = TranscriptAssembler()
        a.add(text: "Hel", start: 0, end: 0.5, isFinal: false, finalizedThrough: 0)
        a.add(text: "Hello there", start: 0, end: 1.2, isFinal: false, finalizedThrough: 0)
        a.add(text: "Hello there.", start: 0, end: 1.2, isFinal: true, finalizedThrough: 1.2)
        a.add(text: " How are", start: 1.2, end: 2.0, isFinal: false, finalizedThrough: 1.2)
        a.add(text: " How are you?", start: 1.2, end: 2.4, isFinal: true, finalizedThrough: 2.4)
        check(a.text == "Hello there. How are you?", "Finals replace the volatile text over their range: \(a.text)")
        check(a.unfinalizedCharacters == 0, "A fully finalized session reports no unfinalized text")
    }
    // The session ends while the last words are still volatile: they are kept.
    do {
        var a = TranscriptAssembler()
        a.add(text: "Ship it", start: 0, end: 0.9, isFinal: true, finalizedThrough: 0.9)
        a.add(text: " now", start: 0.9, end: 1.3, isFinal: false, finalizedThrough: 0.9)
        a.add(text: " now please", start: 0.9, end: 1.7, isFinal: false, finalizedThrough: 0.9)
        check(a.text == "Ship it now please", "The last volatile text is kept, not dropped: \(a.text)")
        check(a.unfinalizedCharacters == "now please".count, "Kept volatile text is counted: \(a.unfinalizedCharacters)")
    }
    // An engine that never marks anything final (DictationTranscriber's short preset).
    do {
        var a = TranscriptAssembler()
        a.add(text: "No", start: 0, end: 0.4, isFinal: false, finalizedThrough: 0)
        a.add(text: "No, wait", start: 0, end: 0.9, isFinal: false, finalizedThrough: 0)
        check(a.text == "No, wait", "With no final results the latest volatile text is the transcript: \(a.text)")
    }
    // Apple need not reissue a volatile result as final when finalization
    // leaves it unchanged: a later result's finalization time settles it.
    do {
        var a = TranscriptAssembler()
        a.add(text: "First part.", start: 0, end: 1.26, isFinal: false, finalizedThrough: 0)
        a.add(text: " Second part.", start: 1.26, end: 5.7, isFinal: true, finalizedThrough: 5.7)
        check(a.text == "First part. Second part.", "Volatile text finalized through by a later result is kept: \(a.text)")
        a.add(text: " Third.", start: 5.7, end: 6.5, isFinal: true, finalizedThrough: 6.5)
        check(a.text == "First part. Second part. Third.", "Settled text is never removed by later results: \(a.text)")
    }
    // A final over part of a longer volatile guess replaces that guess.
    do {
        var a = TranscriptAssembler()
        a.add(text: "one two three", start: 0, end: 3, isFinal: false, finalizedThrough: 0)
        a.add(text: "One two", start: 0, end: 2, isFinal: true, finalizedThrough: 2)
        a.add(text: " three.", start: 2, end: 3, isFinal: true, finalizedThrough: 3)
        check(a.text == "One two three.", "No word is duplicated when finals split a volatile guess: \(a.text)")
    }
    // Results that arrive out of audio order still join in audio order.
    do {
        var a = TranscriptAssembler()
        a.add(text: " later", start: 2, end: 3, isFinal: true, finalizedThrough: 3)
        a.add(text: "earlier", start: 0, end: 1, isFinal: true, finalizedThrough: 3)
        check(a.text == "earlier later", "Segments join in audio order: \(a.text)")
    }
    // Invalid times fall back to arrival order rather than losing text.
    do {
        var a = TranscriptAssembler()
        a.add(text: "a", start: .nan, end: .nan, isFinal: true, finalizedThrough: .nan)
        a.add(text: " b", start: .nan, end: .nan, isFinal: true, finalizedThrough: .nan)
        check(a.text == "a b", "Invalid times keep arrival order: \(a.text)")
    }
    // Empty session.
    check(TranscriptAssembler().text.isEmpty, "No results is empty text")
}

// MARK: - Converter quality and end-of-recording flush (M4, M3)

/// `seconds` of a 440 Hz tone at `rate`, sliced like the microphone tap.
func toneBuffers(rate: Double, seconds: Double, chunk: Int) -> [AVAudioPCMBuffer] {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let total = Int(rate * seconds)
    var out: [AVAudioPCMBuffer] = []
    var position = 0
    while position < total {
        let n = min(chunk, total - position)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        b.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { b.floatChannelData![0][i] = 0.25 * sin(2 * .pi * 440 * Float(position + i) / Float(rate)) }
        out.append(b)
        position += n
    }
    return out
}

func testCaptureConverter() {
    // Apple's speech engine takes 16 kHz 16-bit mono on this Mac (bench --info).
    let speech = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    for (rate, chunk) in [(48000.0, 4800), (44100.0, 4410)] {
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        guard let converter = try? CaptureConverter(from: source, to: speech) else { check(false, "A converter is created"); return }
        check(converter.algorithm == AVSampleRateConverterAlgorithm_Mastering, "The converter uses the Mastering algorithm")
        check(converter.quality == AVAudioQuality.max.rawValue, "The converter runs at maximum quality")
        let input = toneBuffers(rate: rate, seconds: 1.0, chunk: chunk)
        let clock = ContinuousClock(), start = clock.now
        var converted = 0
        for buffer in input { converted += Int(converter.convert(buffer)?.frameLength ?? 0) }
        let elapsed = clock.now - start
        let tail = converter.flush()
        let tailFrames = tail.reduce(0) { $0 + Int($1.frameLength) }
        let heldMs = Double(tailFrames) / 16.0
        print(String(format: "  %.0f Hz -> 16 kHz: %d frames before flush, %d held back (%.1f ms), 1 s converted in %@",
                     rate, converted, tailFrames, heldMs, "\(elapsed)"))
        check(converted < 16000, "Without a flush the converter holds audio back (\(converted) of 16000 frames)")
        check(abs(converted + tailFrames - 16000) <= 2, "The flush returns the held-back audio: \(converted + tailFrames) of 16000 frames")
        check(tail.allSatisfy { $0.format == speech }, "The tail is in the speech engine's format")
        // The held-back audio is the end of the tone, not silence.
        if let last = tail.last, let samples = last.int16ChannelData?[0], last.frameLength > 0 {
            let peak = (0..<Int(last.frameLength)).map { abs(Int(samples[$0])) }.max() ?? 0
            check(peak > 1000, "The flushed tail carries the last sound (peak \(peak))")
        }
        check(converter.flush().isEmpty, "A second flush returns nothing")
        check(converter.convert(input[0]) == nil, "A flushed converter takes no more input")
        check(elapsed < .milliseconds(250), "Maximum quality converts a second of audio in well under real time (\(elapsed))")
    }
}

/// Multi-channel microphones (P-F8, P-F9). AVAudioConverter alone turned a
/// discrete or unknown layout into digital silence and kept only channel 1
/// of a layout-free source; every channel is now averaged, as on Windows.
func testChannelMix() {
    let speech = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let apple = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    func source(_ channels: AVAudioChannelCount, _ layout: String, interleaved: Bool = false) -> AVAudioFormat {
        switch layout {
        case "discrete":
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: interleaved,
                                 channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!)
        case "unknown":
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: interleaved,
                                 channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Unknown | UInt32(channels))!)
        default:
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: channels, interleaved: interleaved)!
        }
    }
    /// Level in dB of the converted 1 kHz tone against the same tone on a mono mic.
    func level(_ format: AVAudioFormat, toneOn live: Int, to target: AVAudioFormat) -> Double? {
        guard let converter = try? CaptureConverter(from: format, to: target) else { return nil }
        let channels = Int(format.channelCount)
        var out: [Float] = []
        var k = 0
        for _ in 0..<10 {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            b.frameLength = 4800
            for i in 0..<4800 {
                let value = Float(0.5 * sin(2 * .pi * 1000 * Double(k) / 48000))
                for channel in 0..<channels {
                    let sample = channel == live ? value : 0
                    if format.isInterleaved { b.floatChannelData![0][i * channels + channel] = sample }
                    else { b.floatChannelData![channel][i] = sample }
                }
                k += 1
            }
            guard let o = converter.convert(b) else { continue }
            if let f = o.floatChannelData?[0] { out += UnsafeBufferPointer(start: f, count: Int(o.frameLength)) }
            else if let s = o.int16ChannelData?[0] { out += UnsafeBufferPointer(start: s, count: Int(o.frameLength)).map { Float($0) / 32768 } }
        }
        guard out.count > 8000 else { return nil }
        let tail = out.suffix(8000)
        let rms = sqrt(tail.reduce(0) { $0 + Double($1 * $1) } / Double(tail.count))
        return 20 * log10(max(rms, 1e-12) / (0.5 / sqrt(2)))
    }
    // AVAudioFormat needs a layout past two channels.
    for (layout, counts) in [("discrete", [2, 4]), ("unknown", [2, 4]), ("none", [2])] as [(String, [AVAudioChannelCount])] {
        for channels in counts {
            let expected = -20 * log10(Double(channels))
            for live in 0..<Int(channels) {
                for target in [speech, apple] {
                    let got = level(source(channels, layout), toneOn: live, to: target)
                    check(got.map { abs($0 - expected) < 0.5 } == true,
                          String(format: "%@ layout, %d channels, tone on input %d: mono at %.1f dB (got %@)", layout, channels, live + 1,
                                 expected, got.map { String(format: "%.1f dB", $0) } ?? "nothing"))
                }
            }
        }
    }
    let interleaved = level(source(2, "discrete", interleaved: true), toneOn: 1, to: speech)
    check(interleaved.map { abs($0 + 6.02) < 0.5 } == true, "Interleaved stereo mixes the same way (got \(String(describing: interleaved)))")
    let mono = level(source(1, "none"), toneOn: 0, to: speech)
    check(mono.map { abs($0) < 0.5 } == true, "A mono mic passes at full level (got \(String(describing: mono)))")
}


// MARK: - Debug text log (M7) and session metrics (M6)

func mode(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

func testDebugTextLog() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("sona-debug-text-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let folder = root.appendingPathComponent("debug-text")
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var clock = start
    let until = start.addingTimeInterval(7 * 24 * 3600)

    // Off by default: no setting means no folder and no file.
    do {
        let log = DebugTextLog(until: nil, folder: folder, now: { clock })
        log.housekeep()
        log.record(engineText: "alpha", cleanedText: "Alpha.", cleanupStatus: "ok", reason: nil)
        check(!fm.fileExists(atPath: folder.path), "Off by default writes nothing and creates no folder")
    }

    // On: folder 0700 and file 0600, one JSON line per dictation.
    let on = DebugTextLog(until: until, folder: folder, now: { clock })
    on.record(engineText: "hello world", cleanedText: "Hello, world.", cleanupStatus: "ok", reason: nil)
    on.record(engineText: "second one", cleanedText: nil, cleanupStatus: "fallback", reason: "cleanup_guard_new_words")
    let today = on.fileURL(for: clock)
    check(mode(folder.path) == 0o700, "Debug folder is 0700 (got \(String(mode(folder.path), radix: 8)))")
    check(mode(today.path) == 0o600, "Debug file is 0600 (got \(String(mode(today.path), radix: 8)))")
    let lines = ((try? String(contentsOf: today, encoding: .utf8)) ?? "").split(separator: "\n")
    check(lines.count == 2, "One line per dictation (\(lines.count))")
    if lines.count == 2,
       let first = try? JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any],
       let second = try? JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any] {
        check(first["engineText"] as? String == "hello world" && first["cleanedText"] as? String == "Hello, world.",
              "The line holds the engine and cleaned text")
        check(first["cleanupStatus"] as? String == "ok" && first["reason"] is NSNull && first["time"] is String,
              "Status, null reason and time are present")
        check(second["cleanedText"] is NSNull && second["reason"] as? String == "cleanup_guard_new_words",
              "No cleaned text is null; the guard code is kept exactly")
    } else {
        check(false, "Debug lines are JSON objects")
    }

    // Prune: a file from more than seven days ago goes, a recent one stays.
    let old = folder.appendingPathComponent("2020-01-01.jsonl")
    let recent = on.fileURL(for: clock.addingTimeInterval(-3 * 24 * 3600))
    fm.createFile(atPath: old.path, contents: Data("{}\n".utf8))
    fm.createFile(atPath: recent.path, contents: Data("{}\n".utf8))
    on.housekeep()
    check(!fm.fileExists(atPath: old.path), "Files older than seven days are pruned")
    check(fm.fileExists(atPath: recent.path) && fm.fileExists(atPath: today.path), "Files inside seven days are kept")
    fm.createFile(atPath: old.path, contents: Data("{}\n".utf8))
    on.record(engineText: "third", cleanedText: "Third.", cleanupStatus: "ok", reason: nil)
    check(!fm.fileExists(atPath: old.path), "Each write prunes old files first")

    // After until: everything is deleted and nothing more is written.
    clock = until.addingTimeInterval(1)
    on.housekeep()
    let left = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
    check(left.isEmpty, "Once until has passed every file is deleted (\(left))")
    on.record(engineText: "late", cleanedText: "Late.", cleanupStatus: "ok", reason: nil)
    let after = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
    check(after.isEmpty, "Nothing is written after until (\(after))")
    check(!on.isOn, "The log reports off after until")
}

func testDebugTextLogConfig() {
    func decode(_ json: String) -> Config? { try? JSONDecoder().decode(Config.self, from: Data(json.utf8)) }
    let without = decode(#"{"hotkey":"right-command","vocabulary":["Sona"]}"#)
    check(without != nil && without?.debugTextLogUntil == nil, "No key decodes, off")
    let with = decode(#"{"vocabulary":["Sona"],"debugTextLog":{"until":"2026-11-11T17:00:00-05:00"}}"#)
    check(with?.debugTextLogUntil == ISO8601DateFormatter().date(from: "2026-11-11T22:00:00Z"), "A valid until decodes")
    check(with?.vocabulary == ["Sona"], "The rest of the config still decodes")
    for bad in [#"{"debugTextLog":{"until":"next week"}}"#, #"{"debugTextLog":true}"#,
                #"{"debugTextLog":{"until":42}}"#, #"{"debugTextLog":{}}"#, #"{"debugTextLog":null}"#] {
        let config = decode(#"{"vocabulary":["Sona"],"# + bad.dropFirst())
        check(config != nil && config?.debugTextLogUntil == nil && config?.vocabulary == ["Sona"],
              "A malformed value is off and never fails the file: \(bad)")
    }
    check(Config().debugTextLogUntil == nil, "A new config is off")
}

/// The app records through DebugTextLog.fromConfigFile, which reads the file
/// at each write. A hand edit that removes the entry, with Sona still running,
/// must purge the folder and stop the very next record.
func testDebugTextLogReadsConfigEachWrite() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("sona-debug-config-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    let configURL = root.appendingPathComponent("config.json")
    let folder = root.appendingPathComponent("debug-text")
    let clock = ISO8601DateFormatter().date(from: "2026-11-05T15:00:00Z")!
    func writeConfig(_ json: String) { try? Data(json.utf8).write(to: configURL) }
    func record(_ text: String) {
        DebugTextLog.fromConfigFile(configURL, folder: folder, now: { clock })
            .record(engineText: text, cleanedText: text, cleanupStatus: "ok", reason: nil)
    }
    func contents() -> [String] { (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] }

    writeConfig(#"{"vocabulary":["Sona"],"debugTextLog":{"until":"2026-11-11T17:00:00-05:00"}}"#)
    record("while on")
    check(contents().count == 1, "With the entry on disk, a record writes (\(contents()))")

    // Removed by hand while running: the next record purges and writes nothing.
    writeConfig(#"{"vocabulary":["Sona"]}"#)
    record("after removal")
    check(contents().isEmpty, "A removed entry stops the next record and purges the folder (\(contents()))")

    // Turned back on, then the file goes missing or malformed: both read as off.
    writeConfig(#"{"vocabulary":["Sona"],"debugTextLog":{"until":"2026-11-11T17:00:00-05:00"}}"#)
    record("on again")
    check(contents().count == 1, "Restoring the entry turns it back on (\(contents()))")
    writeConfig("{ not json")
    record("malformed")
    check(contents().isEmpty, "A malformed config file reads as off (\(contents()))")
    writeConfig(#"{"vocabulary":["Sona"],"debugTextLog":{"until":"2026-11-11T17:00:00-05:00"}}"#)
    record("on once more")
    try? fm.removeItem(at: configURL)
    record("missing")
    check(contents().isEmpty, "A missing config file reads as off (\(contents()))")
}

func testSessionMetrics() {
    check(SessionMetrics.changedPercent(raw: "one two three four", cleaned: "one two three four") == 0, "No change is 0%")
    check(SessionMetrics.changedPercent(raw: "one two three four", cleaned: "one too three four") == 25, "One word of four is 25%")
    check(SessionMetrics.changedPercent(raw: "one two three four", cleaned: "one two three") == 25, "A dropped word counts")
    check(SessionMetrics.changedPercent(raw: "one two", cleaned: "one two three four") == 100, "Added words count, capped at 100%")
    check(SessionMetrics.changedPercent(raw: "one two three", cleaned: nil) == 0, "No cleaned text is 0%")
    check(SessionMetrics.changedPercent(raw: "", cleaned: "") == 0, "Empty text is 0%")
    check(SessionMetrics.wordEditDistance(["a", "b", "c"], ["a", "c", "d"]) == 2, "Word edit distance")

    let sentence = "Please schedule the quarterly harbor inspection with Marguerite tomorrow"
    let cleaned = "Please schedule the quarterly harbour inspection with Marguerite tomorrow."
    let line = SessionMetrics.line(keyToFirstAudioMs: 182, firstAudioDbfs: -41.6, inputDevice: "MacBook Pro Microphone",
                                   holdMs: 2440, cleanupStatus: "ok", reason: nil,
                                   changedPercent: SessionMetrics.changedPercent(raw: sentence, cleaned: cleaned))
    let lowered = line.lowercased()
    for word in Set(SessionMetrics.words(sentence + " " + cleaned).map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }) {
        check(!lowered.contains(word), "The metrics line holds no transcript word: \(word)")
    }
    check(line.contains("firstAudioMs=182") && line.contains("firstAudioDbfs=-42") && line.contains("holdMs=2440")
          && line.contains("wordsChanged=22%") && line.contains("reason=none"), "Metrics line fields: \(line)")
    let missing = SessionMetrics.line(keyToFirstAudioMs: nil, firstAudioDbfs: nil, inputDevice: nil, holdMs: nil,
                                      cleanupStatus: "fallback", reason: "cleanup_guard_dropped_words", changedPercent: 0)
    check(missing.contains("firstAudioMs=none") && missing.contains("reason=cleanup_guard_dropped_words"), "Missing numbers read none")
}

@main
struct DictationPipelineMain {
    static func main() {
        testTranscriptAssembler()
        testCaptureConverter()
        testChannelMix()
        testDebugTextLog()
        testDebugTextLogConfig()
        testDebugTextLogReadsConfigEachWrite()
        testSessionMetrics()
        print("Dictation pipeline: \(checks) checks passed; no microphone, speech engine or window.")
    }
}
