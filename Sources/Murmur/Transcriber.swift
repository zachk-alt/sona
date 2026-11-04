import AVFoundation
import Foundation
import Speech

protocol Transcriber: AnyObject {
    /// Audio format the engine wants buffers in, once known.
    var requiredFormat: AVAudioFormat? { get async }
    /// Pay one-time model and shader warmup before the user ever presses the key.
    func prepare() async
    /// Open a session. Buffers fed after this are part of one utterance.
    func begin() async throws
    func feed(_ buffer: AVAudioPCMBuffer)
    /// Close the session and return the final text.
    func finish() async throws -> String
    /// Abandon the session without transcribing.
    func cancel() async
}

enum TranscriptionError: Error {
    case unavailable(String)
    case noLocale(String)
}

/// Apple's on-device SpeechAnalyzer, macOS 26.
///
/// Streams audio locally and prepares missing Apple speech assets on first use.
/// A fresh process warms the model at launch to reduce the first dictation delay.
final class AppleTranscriber: Transcriber {

    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    /// Resolved and reserved once; the reservation is what is expensive, not
    /// the module.
    private var resolvedLocale: Locale?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var collector: Task<TranscriptAssembler, Error>?
    private var cachedFormat: AVAudioFormat?
    /// Characters of the last finished session that the engine never marked
    /// final. Zero on a normal session. Read by the bench, never logged as text.
    private(set) var lastUnfinalizedCharacters = 0

    init(locale: Locale = Locale.current) {
        self.locale = locale
    }

    /// Best supported locale, preferring the user's own.
    private static func resolveLocale(_ preferred: Locale) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.unavailable("SpeechTranscriber is not available")
        }
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) {
            return match
        }
        if let english = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
            return english
        }
        throw TranscriptionError.noLocale("No supported speech language is available")
    }

    /// Returns a FRESH module every call.
    ///
    /// A SpeechTranscriber is single-use: handing the same instance to a second
    /// SpeechAnalyzer traps (SIGTRAP, no error, no message). Round one of a
    /// two-round self-test passes and round two dies, which is why this is
    /// tested twice rather than once.
    private func makeTranscriber() async throws -> SpeechTranscriber {
        let resolved: Locale
        if let resolvedLocale {
            resolved = resolvedLocale
        } else {
            resolved = try await Self.resolveLocale(locale)
            resolvedLocale = resolved
        }
        let new = SpeechTranscriber(locale: resolved, preset: .transcription)

        // A locale must be RESERVED before the analyzer will accept the module.
        // Without this, `start(inputSequence:)` fails with a bare `nilError`
        // that names neither the locale nor the reservation as the cause.
        if await !AssetInventory.reservedLocales.contains(where: { $0.identifier == resolved.identifier }) {
            _ = try? await AssetInventory.reserve(locale: resolved)
        }

        // New installations may have no model yet. Ask Apple to install only
        // when this resolved locale is absent, preserving the fast installed path.
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier == resolved.identifier }) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [new]) {
                try await request.downloadAndInstall()
            }
        }

        transcriber = new
        return new
    }

    var requiredFormat: AVAudioFormat? {
        get async {
            if let cachedFormat { return cachedFormat }
            guard let t = try? await makeTranscriber() else { return nil }
            let format = Self.bestFormat(await t.availableCompatibleAudioFormats)
            cachedFormat = format
            return format
        }
    }

    /// Absorbs the 2.3-2.6 s first-run cost at launch instead of on first use.
    func prepare() async {
        guard let t = try? await makeTranscriber() else { return }
        let warmup = SpeechAnalyzer(modules: [t])
        try? await warmup.prepareToAnalyze(in: Self.bestFormat(await t.availableCompatibleAudioFormats))
        // Deliberately discarded. Both the analyzer and its module are spent.
        await warmup.cancelAndFinishNow()
    }

    func installAssets() async throws {
        _ = try await makeTranscriber()
    }

    func begin() async throws {
        let transcriber = try await makeTranscriber()
        self.transcriber = transcriber

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation

        // Never reuse the analyzer from prepare(): it is bound to the throwaway
        // module that warmed the models up.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Drain results concurrently. Volatile results are provisional and a
        // later result over the same audio replaces them; text the engine
        // never marks final is still kept (TranscriptAssembler).
        collector = Task {
            var assembler = TranscriptAssembler()
            for try await result in transcriber.results {
                assembler.add(text: String(result.text.characters),
                              start: result.range.start.seconds, end: result.range.end.seconds,
                              isFinal: result.isFinal,
                              finalizedThrough: result.resultsFinalizationTime.seconds)
            }
            return assembler
        }

        try await analyzer.start(inputSequence: stream)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async throws -> String {
        continuation?.finish()
        continuation = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()

        let assembled = try await collector?.value ?? TranscriptAssembler()
        collector = nil
        analyzer = nil
        transcriber = nil
        lastUnfinalizedCharacters = assembled.unfinalizedCharacters
        if assembled.unfinalizedCharacters > 0 {
            // A count only: transcript text never enters the diagnostics log.
            Log.write("transcribe: kept \(assembled.unfinalizedCharacters) chars the engine never marked final")
        }
        return assembled.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        continuation?.finish()
        continuation = nil
        collector?.cancel()
        collector = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        transcriber = nil
    }
    /// `availableCompatibleAudioFormats` is not ordered by quality: the first
    /// entry offered on this machine was 8 kHz, which is telephone grade.
    /// Prefer 16 kHz, the standard rate for speech models, then the highest on
    /// offer.
    private static func bestFormat(_ formats: [AVAudioFormat]) -> AVAudioFormat? {
        if let sixteen = formats.first(where: { $0.sampleRate == 16000 }) { return sixteen }
        return formats.max(by: { $0.sampleRate < $1.sampleRate }) ?? formats.first
    }
}

/// Joins one session's results into its text, in audio order.
///
/// A result is final or volatile. A newer result over the same audio replaces
/// any volatile text there. Apple's engine is not required to reissue a
/// volatile result as final when finalization leaves it unchanged
/// (`resultsFinalizationTime` documentation), and DictationTranscriber's short
/// dictation preset never marked anything final, so a final-only filter can
/// drop words that were spoken. Text that was never final is therefore kept
/// rather than dropped, and counted for diagnostics.
struct TranscriptAssembler {
    private struct Segment {
        var start: Double
        var end: Double
        var text: String
        /// Reported final, or finalized through by a later result.
        var settled: Bool
        /// Reported final by its own result. What the old filter kept.
        var reportedFinal: Bool
    }
    private var segments: [Segment] = []

    /// - Parameters:
    ///   - start, end: the result's audio range in seconds.
    ///   - finalizedThrough: the result's `resultsFinalizationTime` in seconds.
    mutating func add(text: String, start: Double, end: Double, isFinal: Bool, finalizedThrough: Double) {
        // Invalid times keep arrival order: the segment goes after the last one.
        let tail = segments.last?.end ?? 0
        let lower = start.isFinite ? start : tail
        let upper = end.isFinite ? max(end, lower) : lower
        // Superseded provisional text over the same audio goes first, so a
        // final that replaces a volatile result never keeps both.
        segments.removeAll { old in
            !old.settled && ((old.start < upper && lower < old.end) || (old.start == lower && old.end == upper))
        }
        // Earlier results this one finalizes through can no longer change.
        if finalizedThrough.isFinite {
            for index in segments.indices where segments[index].end <= finalizedThrough {
                segments[index].settled = true
            }
        }
        let segment = Segment(start: lower, end: upper, text: text, settled: isFinal, reportedFinal: isFinal)
        let index = segments.firstIndex { $0.start > lower } ?? segments.endIndex
        segments.insert(segment, at: index)
    }

    var text: String { segments.map(\.text).joined() }

    /// Characters kept that no result ever reported final.
    var unfinalizedCharacters: Int {
        segments.filter { !$0.reportedFinal }.reduce(0) { $0 + $1.text.trimmingCharacters(in: .whitespacesAndNewlines).count }
    }
}
