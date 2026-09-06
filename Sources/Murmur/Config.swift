import Foundation

/// User-tunable settings, read from ~/.config/murmur/config.json when present.
struct Config: Codable {
    var hotkey = "right-command"
    var setupComplete = false
    var ai = AISettings()


    /// Proper nouns the recognizer reliably mangles. Injected into the cleanup
    /// prompt, where it was measured to repair exactly this class of error.
    /// A vocabulary list is a first-class feature here, not a nicety: no
    /// transcription engine tested gets developer and company jargon right
    /// unaided.
    var vocabulary: [String] = []

    /// Bundle identifiers that get the conservative cleanup pass, because the
    /// text is probably a command or code rather than prose.
    var strictModeBundleIDs: [String] = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.jetbrains.intellij",
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "dev.zed.Zed",
    ]

    /// Explicit path to the `claude` binary, when the usual locations miss.
    var claudePath: String?

    /// Set false to skip the LLM pass entirely and insert raw transcripts.
    var cleanupEnabled: Bool = true

    /// Only react to right Command when the focused element accepts typing.
    /// Set false to record regardless of what has focus.
    var requireTextField: Bool = true

    /// Which start/stop sound, by id from the Sound menu. Unset means the
    /// default. `startSound` / `stopSound` files override this when set.
    var sound: String?

    /// Optional audio files to play instead of the chosen sound. Any format
    /// AVAudioFile reads. A bad path falls back silently.
    var startSound: String?
    var stopSound: String?

    /// Reverb on the start/stop cues, 0 (dry) to 1 (drenched). Default is
    /// dry: "clean and full" means the fullness comes from the octaves in the
    /// sound itself, not from room.
    var cueReverb: Double = 0.0

    private enum CodingKeys: String, CodingKey {
        case hotkey, setupComplete, ai, vocabulary, strictModeBundleIDs, claudePath, cleanupEnabled,
             requireTextField, sound, startSound, stopSound, cueReverb
    }

    init() {}

    /// Every key optional. The synthesized decoder fails the WHOLE file when
    /// one key is missing, which silently reset the vocabulary to empty the
    /// first time a new setting was added. Never again.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        setupComplete = try c.decodeIfPresent(Bool.self, forKey: .setupComplete) ?? true
        ai = try c.decodeIfPresent(AISettings.self, forKey: .ai) ?? d.ai
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? d.vocabulary
        strictModeBundleIDs = try c.decodeIfPresent([String].self, forKey: .strictModeBundleIDs) ?? d.strictModeBundleIDs
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        cleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? d.cleanupEnabled
        requireTextField = try c.decodeIfPresent(Bool.self, forKey: .requireTextField) ?? d.requireTextField
        sound = try c.decodeIfPresent(String.self, forKey: .sound)
        startSound = try c.decodeIfPresent(String.self, forKey: .startSound)
        stopSound = try c.decodeIfPresent(String.self, forKey: .stopSound)
        cueReverb = try c.decodeIfPresent(Double.self, forKey: .cueReverb) ?? d.cueReverb
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/murmur/config.json")
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(
            at: Self.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.configURL)
        }
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return config
    }

    /// Writes a template on first run so the vocabulary list is discoverable
    /// rather than buried in a README.
    static func writeTemplateIfMissing() {
        let url = configURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var template = Config()
        template.vocabulary = ["Claude", "Haiku", "macOS", "Xcode", "SwiftUI"]
        if let data = try? encoder.encode(template) {
            try? data.write(to: url)
        }
    }
}

/// Only provider settings and environment variable names, never secrets.
struct AISettings: Codable {
    var provider = "auto"
    var model = "economy"
    var timeoutMs = 12000
    var executable: String?
    var args: [String]?
    var endpoint: String?
    var apiKeyEnv: String?
    enum CodingKeys: String, CodingKey { case provider, model, timeoutMs, executable, args, endpoint, apiKeyEnv }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "auto"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "economy"
        timeoutMs = max(500, min(30000, try c.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 12000))
        executable = try c.decodeIfPresent(String.self, forKey: .executable)
        args = try c.decodeIfPresent([String].self, forKey: .args)
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint)
        apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv)
    }
}
