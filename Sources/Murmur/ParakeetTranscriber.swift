import CoreML
import FluidAudio
import Foundation

/// Parakeet Ultra through FluidAudio (Apache-2.0, pinned in Package.swift).
///
/// The only file that imports FluidAudio, so the standalone test harness can
/// compile everything else. The model is the pinned copy ModelStore downloads
/// and checks; FluidAudio's own downloader is never used. It loads once, on a
/// task at launch, and stays loaded. No custom vocabulary or word boost: the
/// 2026-11-04 audit found the boost wrote listed words that were never said.
/// Transcript text never enters the log; only counts and timings do.
final class ParakeetRecognizer: SampleRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var manager: AsrManager?
    private var decoderLayers = 2
    private var busy = false
    private var loadTask: Task<Void, Never>?

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return manager != nil && !busy
    }

    /// Download if needed, check, load and warm the model, all in this process.
    /// Apple serves every session until this finishes; a failure leaves Apple
    /// serving and is retried at the next launch.
    func startLoading(store: ModelStore = ModelStore(manifest: .parakeetUltra, root: ModelStore.defaultRoot)) {
        lock.lock(); defer { lock.unlock() }
        guard loadTask == nil else { return }
        loadTask = Task.detached(priority: .utility) { [weak self] in
            await self?.load(store)
        }
    }

    /// Waits for the launch load (the self-test and the bench use this).
    func waitUntilLoaded() async { await loadTask?.value }

    private func load(_ store: ModelStore) async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let outcome = try await store.ensure()
            let checked = clock.now
            Log.write("parakeet: model ready (cheap_check=\(outcome.cheap) downloaded=\(outcome.downloaded) " +
                      "verified=\(outcome.verified)) in \(Self.ms(checked - start)) ms")
            let version = AsrModelVersion.ultra
            let models = try AsrModels.loadLocal(from: store.directory, version: version)
            let asr = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId),
                                                   encoderHiddenSize: version.encoderHiddenSize))
            try await asr.loadModels(models)
            let layers = await asr.decoderLayerCount
            // One pass over a second of silence compiles and places the model
            // now, so the first real dictation is not the slow one.
            var state = TdtDecoderState.make(decoderLayers: layers)
            _ = try? await asr.transcribe([Float](repeating: 0, count: 16000), decoderState: &state)
            lock.withLock {
                manager = asr
                decoderLayers = layers
            }
            Log.write("parakeet: loaded in \(Self.ms(clock.now - checked)) ms")
        } catch {
            Log.write("parakeet: not available (\(type(of: error))); Apple serves")
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let claimed: (AsrManager, Int)? = lock.withLock {
            guard let manager else { return nil }
            busy = true
            return (manager, decoderLayers)
        }
        guard let (asr, layers) = claimed else { throw ASRError.notInitialized }
        defer { lock.withLock { busy = false } }
        // Long recordings: FluidAudio splits audio over its 15 s model window
        // into overlapping chunks itself (ChunkProcessor).
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try await asr.transcribe(samples, decoderState: &state)
        return result.text
    }

    private static func ms(_ duration: Duration) -> Int {
        Int((Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15).rounded())
    }
}

/// Builds the app's engine slot from the config at launch.
enum SpeechEngines {
    /// One Parakeet model for the whole process, loaded once and kept, even
    /// when a stalled session makes AppState replace its transcriber. A user
    /// whose language is not English keeps Apple for every session, and the
    /// model is never downloaded or loaded (EnginePolicy.parakeetSupports).
    static func makeFactory(_ config: Config) -> () -> Transcriber {
        let setting = config.speechEngine
        let locale = Locale.current
        let loads = EnginePolicy.loadsParakeet(setting, locale: locale)
        let parakeet: ParakeetRecognizer? = loads ? ParakeetRecognizer() : nil
        parakeet?.startLoading()
        Log.write("engine: configured=\(setting.rawValue)" +
                  (setting == .parakeet && !loads ? " language=not-english; Apple serves, no Parakeet download" : ""))
        let cap = AppState.Deadlines(bridgeTimeout: 0).parakeet
        return {
            DictationTranscriber(setting: setting, locale: locale, parakeet: parakeet,
                                 makeApple: { AppleTranscriber(locale: locale) }, parakeetCap: cap)
        }
    }
}
