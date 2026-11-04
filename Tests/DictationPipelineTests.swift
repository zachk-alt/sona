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

@main
struct DictationPipelineMain {
    static func main() {
        testTranscriptAssembler()
        testCaptureConverter()
        print("Dictation pipeline: \(checks) checks passed; no microphone, speech engine or window.")
    }
}
