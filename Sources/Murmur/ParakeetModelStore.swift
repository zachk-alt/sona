import CryptoKit
import Foundation

/// One file of a pinned model: its path in the repository, byte size and SHA-256.
struct ModelFile: Equatable {
    let path: String
    let size: Int64
    let sha256: String
}

/// A model pinned to one repository commit, every file listed with its size and hash.
struct ModelManifest {
    let name: String
    let repository: String
    let commit: String
    let files: [ModelFile]

    func url(for file: ModelFile) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(commit)/\(file.path)")!
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Parakeet Ultra (CC BY 4.0), the Core ML conversion FluidInference
    /// publishes, pinned to one commit. Sources, checked 2026-11-04:
    /// - commit: https://huggingface.co/api/models/FluidInference/parakeet-ultra-coreml
    ///   ("sha" 95eaa59a39d4394f047a4dc5cce480388a60d1b6, last modified 2026-09-24)
    /// - sizes and hashes: https://huggingface.co/api/models/FluidInference/parakeet-ultra-coreml/tree/95eaa59a39d4394f047a4dc5cce480388a60d1b6?recursive=true&expand=true
    ///   (Git LFS files list their SHA-256 there; the small files list a Git
    ///   blob id, and their SHA-256 below was taken from a copy whose Git blob
    ///   ids matched those, as every LFS hash matched too)
    /// - files: https://huggingface.co/FluidInference/parakeet-ultra-coreml/resolve/<commit>/<path>
    /// README.md and .gitattributes are not needed to run the model.
    static let parakeetUltra = ModelManifest(
        name: "parakeet-ultra",
        repository: "FluidInference/parakeet-ultra-coreml",
        commit: "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
        files: [
            ModelFile(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "fe92b6cfaa012abd5248c0bc877832f19807015abffc60d87b8ccc8ccb48b3b5"),
            ModelFile(path: "Decoder.mlmodelc/coremldata.bin", size: 560, sha256: "3b06e66768f0df7e21795f50e2b29300e33eeb1a2579dc42c695279c2d308497"),
            ModelFile(path: "Decoder.mlmodelc/model.mil", size: 13110, sha256: "956f600207f88396017ca5c96cfa3acd5bfee60835a5b44b762e033a8fb28955"),
            ModelFile(path: "Decoder.mlmodelc/weights/weight.bin", size: 23604992, sha256: "02a0d219f281b9665bc10c8768649403b2eebbbf4b44c627041d948e0de11bb4"),
            ModelFile(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "d87101d824d6723cf95304da33755c3c60e762663b9ef2b0c4bd0aa166a09a0d"),
            ModelFile(path: "Encoder.mlmodelc/coremldata.bin", size: 514, sha256: "397a84a4062f563cbc5f56077c674f09a61d85be5090f61d2f1932afb92ac0fe"),
            ModelFile(path: "Encoder.mlmodelc/model.mil", size: 1002653, sha256: "f5d601568a4171d99a314c0fe3f6bc67715da2623732a3fb566e050ea83e5848"),
            ModelFile(path: "Encoder.mlmodelc/weights/weight.bin", size: 594211328, sha256: "315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b"),
            ModelFile(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "68d38ca646aebafa7a9329e2efda50f5767c49e89fdb5f77f212072bb66f97c4"),
            ModelFile(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 592, sha256: "5e3af5a4ce686f6c237cadbd9284e10d333bc0e1546633cd0e430e6194044bc4"),
            ModelFile(path: "JointDecisionv3.mlmodelc/model.mil", size: 11777, sha256: "791b3c3cf3eb2079c84623fc880f6bba008d1366e5f8b03e9a8ed8bd4d7194a0"),
            ModelFile(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12642764, sha256: "3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25"),
            ModelFile(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
            ModelFile(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
            ModelFile(path: "Preprocessor.mlmodelc/metadata.json", size: 2841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
            ModelFile(path: "Preprocessor.mlmodelc/model.mil", size: 28181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
            ModelFile(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
            ModelFile(path: "config.json", size: 414, sha256: "965c69bf500c7be18958df6438dc1ba897721690ae412937ca7c91e28cec1870"),
            ModelFile(path: "parakeet_v3_vocab.json", size: 151122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
            ModelFile(path: "parakeet_vocab.json", size: 151122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        ])
}

enum ModelStoreError: Error, Equatable {
    case badSize(String)
    case badHash(String)
    case missing(String)
    case unsafePath(String)
}

/// Keeps a pinned model in its own folder, downloading and checking each file.
///
/// Every file downloads to a temporary name in the model folder, is checked
/// against the manifest's size and SHA-256, and only then moves to its real
/// name, so a half-written or wrong file is never left where the engine loads
/// from. After a full check a stamp file is written; later launches check
/// sizes plus the stamp instead of hashing 600 MB again.
struct ModelStore {
    let manifest: ModelManifest
    /// The model's own folder: <root>/<name>/<commit>.
    let directory: URL
    /// Fetches one URL to a local file and returns its location. Tests pass
    /// a local copier; the app uses URLSession.
    var fetch: (URL) async throws -> URL

    static let stampName = ".sona-verified"

    init(manifest: ModelManifest, root: URL, fetch: @escaping (URL) async throws -> URL = ModelStore.download) {
        self.manifest = manifest
        directory = root.appendingPathComponent(manifest.name, isDirectory: true)
            .appendingPathComponent(manifest.commit, isDirectory: true)
        self.fetch = fetch
    }

    /// ~/Library/Application Support/Sona/Models
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sona/Models", isDirectory: true)
    }

    private var stampURL: URL { directory.appendingPathComponent(Self.stampName) }
    private var stampText: String { "\(manifest.repository)@\(manifest.commit) files=\(manifest.files.count) bytes=\(manifest.totalBytes)\n" }

    func fileURL(_ file: ModelFile) throws -> URL {
        // The manifest is fixed in source, but a path must never leave the folder.
        guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else {
            throw ModelStoreError.unsafePath(file.path)
        }
        return directory.appendingPathComponent(file.path)
    }

    /// Sizes match and a full check was stamped for this exact manifest.
    func isReadyCheap() -> Bool {
        guard (try? String(contentsOf: stampURL, encoding: .utf8)) == stampText else { return false }
        return manifest.files.allSatisfy { file in
            guard let url = try? fileURL(file) else { return false }
            return Self.size(of: url) == file.size
        }
    }

    /// What one launch did, for a text-free log line.
    struct Outcome: Equatable {
        var downloaded = 0
        var verified = 0
        var cheap = false
    }

    /// Makes the folder match the manifest: keeps verified files, replaces
    /// missing or wrong ones, then stamps it. Throws if any file still fails.
    @discardableResult
    func ensure() async throws -> Outcome {
        if isReadyCheap() { return Outcome(cheap: true) }
        try? FileManager.default.removeItem(at: stampURL)
        removeLeftoverPartials()
        var outcome = Outcome()
        for file in manifest.files {
            let target = try fileURL(file)
            if Self.size(of: target) == file.size, (try? Self.verify(target, file)) != nil {
                outcome.verified += 1
                continue
            }
            try? FileManager.default.removeItem(at: target)
            try await install(file, to: target)
            outcome.downloaded += 1
        }
        // One full pass after downloading, before the stamp says it is good.
        for file in manifest.files { try Self.verify(try fileURL(file), file) }
        try stampText.write(to: stampURL, atomically: true, encoding: .utf8)
        return outcome
    }

    /// A download cut off by a quit or crash can leave a temporary file
    /// behind; it never has a real name, so it is only clutter. Remove it.
    private func removeLeftoverPartials() {
        let manager = FileManager.default
        guard let names = manager.enumerator(atPath: directory.path)?.allObjects as? [String] else { return }
        for name in names where (name as NSString).lastPathComponent.hasSuffix(".partial") {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Fetch to a temporary name, check, then move into place.
    private func install(_ file: ModelFile, to target: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? manager.removeItem(at: temporary) }
        let fetched = try await fetch(manifest.url(for: file))
        defer { try? manager.removeItem(at: fetched) }
        try? manager.removeItem(at: temporary)
        try manager.moveItem(at: fetched, to: temporary)
        try Self.verify(temporary, file)
        try manager.moveItem(at: temporary, to: target)
    }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Size first (cheap), then SHA-256 in 4 MB reads.
    static func verify(_ url: URL, _ file: ModelFile) throws {
        guard let size = size(of: url) else { throw ModelStoreError.missing(file.path) }
        guard size == file.size else { throw ModelStoreError.badSize(file.path) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ModelStoreError.missing(file.path) }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == file.sha256 else { throw ModelStoreError.badHash(file.path) }
    }

    /// URLSession download to a file this process owns. Bounded: a stalled
    /// connection fails instead of holding the launch task forever.
    static func download(_ url: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.httpAdditionalHeaders = ["User-Agent": "Sona"]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (location, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: location)
            throw URLError(.badServerResponse)
        }
        // URLSession deletes its file when this returns; move it somewhere we own.
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent("sona-model-\(UUID().uuidString).download")
        try FileManager.default.moveItem(at: location, to: owned)
        return owned
    }
}
