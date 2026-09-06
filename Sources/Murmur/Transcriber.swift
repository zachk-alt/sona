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
    private var collector: Task<String, Error>?
    private var cachedFormat: AVAudioFormat?

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
        let new = SpeechTranscriber(locale: resolved, preset: .progressiveTranscription)

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

        // Drain results concurrently. The final value is whatever the last
        // non-volatile result carries; earlier ones are provisional and get
        // superseded, so only the accumulated finalized text is kept.
        collector = Task {
            var finalized = AttributedString()
            for try await result in transcriber.results where result.isFinal {
                finalized.append(result.text)
            }
            return String(finalized.characters)
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

        let text = try await collector?.value ?? ""
        collector = nil
        analyzer = nil
        transcriber = nil
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
