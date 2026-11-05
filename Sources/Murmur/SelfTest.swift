import AVFoundation
import Foundation

/// `Murmur --selftest [--engine apple|parakeet] [--realtime] [file.wav ...]`
///
/// Exercises the configured speech engine against audio files, with no
/// microphone and no Accessibility grant, so the pipeline can be verified
/// before any permission is granted.
enum SelfTest {

    /// - Parameters:
    ///   - paths: one file (default fixture) runs two rounds; several files
    ///     run one pass each and print one JSON line per file (the bench).
    ///   - engine: "apple" or "parakeet"; nil uses the config's choice.
    ///   - realtime: feed audio at its own pace, as the microphone would, so
    ///     the finish time is the key-up to text wait.
    ///   - loadParakeet: downloads, checks and loads Parakeet; nil when it
    ///     fails. Passed in from main.swift, so this file never names the
    ///     FluidAudio type and the session recovery harness still compiles it.
    static func run(paths: [String], engine: String?, realtime: Bool,
                    loadParakeet: () async -> SampleRecognizer?) async -> Int32 {
        let sources = paths.isEmpty ? ["windows/tests/Fixtures/jfk.wav"] : paths
        let setting = engine.map { SpeechEngineSetting(configValue: $0) } ?? Config.load().speechEngine
        // The same language rule as the app: Parakeet serves English only.
        let locale = Locale.current
        let usesParakeet = EnginePolicy.loadsParakeet(setting, locale: locale)
        print("Sona self-test")
        print("  engine setting: \(setting.rawValue)")
        if setting == .parakeet, !usesParakeet {
            print("  language: \(locale.identifier) is not English, so Apple serves (\(EngineServed.appleLanguage.rawValue))")
        }
        for source in sources where !FileManager.default.fileExists(atPath: source) {
            print("  FAIL: no such file \(source)")
            return 1
        }

        var parakeet: SampleRecognizer?
        if usesParakeet {
            let clock = ContinuousClock()
            let start = clock.now
            guard let recognizer = await loadParakeet(), recognizer.isReady else {
                print("  FAIL: Parakeet model did not download, verify or load (see Sona's log)")
                return 1
            }
            print("  parakeet: ready in \(ms(clock.now - start))")
            parakeet = recognizer
        }
        let cap = AppState.Deadlines(bridgeTimeout: 0).parakeet
        let transcriber = DictationTranscriber(setting: setting, locale: locale, parakeet: parakeet,
                                               makeApple: { AppleTranscriber(locale: locale) }, parakeetCap: cap,
                                               log: { print("  \($0)") })
        await transcriber.prepare()

        if sources.count == 1 {
            // Two rounds, deliberately. The second one is the real test: the
            // app reuses one engine across dictations, and if that is not
            // legal the failure only appears on the second use.
            for round in 1...2 {
                print("  --- round \(round) ---")
                guard let result = await transcribeOnce(sources[0], transcriber, realtime: realtime) else { return 1 }
                guard !result.text.isEmpty else { print("  FAIL: empty transcript"); return 1 }
                if usesParakeet, transcriber.lastServed != .parakeet {
                    print("  FAIL: Parakeet was configured but \(transcriber.lastServed?.rawValue ?? "nothing") served")
                    return 1
                }
                print("  raw: \(result.text)")
            }
            print("  cleanup: not invoked by the local speech self-test")
            return 0
        }
        for source in sources {
            guard let result = await transcribeOnce(source, transcriber, realtime: realtime) else { return 1 }
            let row: [String: Any] = ["file": source, "text": result.text, "finish_ms": result.finishMs,
                                      "served": transcriber.lastServed?.rawValue ?? ""]
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                print("BENCH \(line)")
            }
        }
        return 0
    }

    private static func transcribeOnce(_ source: String, _ transcriber: Transcriber,
                                       realtime: Bool) async -> (text: String, finishMs: Int)? {
        let clock = ContinuousClock()
        do {
            let start = clock.now
            try await transcriber.begin()
            guard let format = await transcriber.requiredFormat else {
                print("  FAIL: the engine reported no compatible audio format")
                await transcriber.cancel()
                return nil
            }
            try await feed(source, into: transcriber, format: format, realtime: realtime)
            let keyUp = clock.now
            let raw = try await transcriber.finish()
            let finish = clock.now - keyUp
            print("  transcribe: \(ms(clock.now - start)) total, \(ms(finish)) key-up to text")
            return (raw, Int(milliseconds(finish).rounded()))
        } catch {
            print("  FAIL: transcription threw \(error)")
            return nil
        }
    }

    /// Streams the file through the transcriber in realtime-sized chunks, the
    /// way the microphone would deliver it.
    private static func feed(_ path: String,
                             into transcriber: Transcriber,
                             format: AVAudioFormat, realtime: Bool) async throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw TranscriptionError.unavailable("cannot convert \(file.processingFormat)")
        }
        // The microphone path's settings (AudioCapture), so the self-test
        // hears what a dictation would.
        if file.processingFormat.sampleRate != format.sampleRate {
            try catchingFrameworkException {
                converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
                converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            }
        }

        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate * 0.1)
        // Bound the loop by framePosition. AVAudioFile.read THROWS a bare
        // nilError when asked to read at EOF rather than returning zero frames,
        // so "read until empty" is not a valid termination condition.
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            let want = min(chunk, remaining)
            guard want > 0,
                  let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: want) else { break }
            try file.read(into: input, frameCount: want)
            if input.frameLength == 0 { break }

            let ratio = format.sampleRate / file.processingFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { break }

            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return input
            }
            if error == nil, output.frameLength > 0 {
                transcriber.feed(output)
            }
            if realtime {
                try await Task.sleep(for: .milliseconds(Int(Double(input.frameLength) / file.processingFormat.sampleRate * 1000)))
            }
        }
        // End of file: hand on the samples the converter held back, as
        // AudioCapture does when the microphone closes.
        if let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) {
            var error: NSError?
            converter.convert(to: tail, error: &error) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            if error == nil, tail.frameLength > 0 { transcriber.feed(tail) }
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func ms(_ duration: Duration) -> String {
        String(format: "%.0f ms", milliseconds(duration))
    }
}
