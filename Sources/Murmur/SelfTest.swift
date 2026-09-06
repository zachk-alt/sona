import AVFoundation
import Foundation

/// `Murmur --selftest [file.wav]`
///
/// Exercises local transcription against an audio file, with no
/// microphone and no Accessibility grant, so the pipeline can be verified
/// before any permission is granted.
enum SelfTest {

    static func run(path: String?) async -> Int32 {
        let source = path ?? "windows/tests/Fixtures/jfk.wav"
        print("Sona self-test")
        print("  input: \(source)")

        guard FileManager.default.fileExists(atPath: source) else {
            print("  FAIL: no such file")
            return 1
        }

        // Two rounds, deliberately. The second one is the real test: the app
        // reuses one SpeechTranscriber module across dictations, and if that is
        // not legal the failure only appears on the second use, never in a
        // one-shot check.
        let transcriber = AppleTranscriber()
        for round in 1...2 {
            print("  --- round \(round) ---")
            if await !transcribeOnce(source, transcriber) { return 1 }
        }
        return 0
    }

    private static func transcribeOnce(_ source: String, _ transcriber: AppleTranscriber) async -> Bool {
        guard let format = await transcriber.requiredFormat else {
            print("  FAIL: SpeechTranscriber reported no compatible audio format")
            return false
        }
        print("  engine: Apple SpeechTranscriber @ \(Int(format.sampleRate)) Hz")

        let clock = ContinuousClock()
        var raw = ""
        do {
            let start = clock.now
            try await transcriber.begin()
            try feed(source, into: transcriber, format: format)
            raw = try await transcriber.finish()
            print("  transcribe: \(ms(clock.now - start))")
        } catch {
            print("  FAIL: transcription threw \(error)")
            return false
        }

        guard !raw.isEmpty else {
            print("  FAIL: empty transcript")
            return false
        }
        print("  raw: \(raw)")

        print("  cleanup: not invoked by the local speech self-test")
        return true
    }

    /// Streams the file through the transcriber in realtime-sized chunks, the
    /// way the microphone would deliver it.
    private static func feed(_ path: String,
                             into transcriber: Transcriber,
                             format: AVAudioFormat) throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw TranscriptionError.unavailable("cannot convert \(file.processingFormat)")
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
        }
    }

    private static func ms(_ duration: Duration) -> String {
        let millis = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.0f ms", millis)
    }
}
