import Foundation

/// User-tunable settings, read from ~/.config/murmur/config.json when present.
struct Config: Codable {
    var hotkey = "right-command"
    var snippets: [Snippet] = []
    var autoAddToDictionary = false
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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case hotkey, snippets, autoAddToDictionary, setupComplete, ai, vocabulary, strictModeBundleIDs, claudePath, cleanupEnabled,
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
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
        autoAddToDictionary = try c.decodeIfPresent(Bool.self, forKey: .autoAddToDictionary) ?? false
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

    func validationError() -> String? {
        guard HotKeyBinding(hotkey) != nil else { return "Choose a valid dictation shortcut." }
        guard vocabulary.count <= 256, vocabulary.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 100 && !$0.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) }) else { return "Use up to 256 vocabulary entries, each 1 to 100 characters on one line." }
        guard snippets.count <= 128, snippets.allSatisfy({ $0.isValid }), snippets.reduce(0, { $0 + $1.expansion.utf8.count }) <= 65536 else { return "Use up to 128 snippets with a short trigger and a nonempty expansion." }
        let triggers = snippets.map { $0.trigger.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        guard Set(triggers).count == triggers.count else { return "Snippet triggers must be unique." }
        return nil
    }

    /// Merge only app-owned fields and replace atomically. Unknown settings survive.
    @discardableResult
    func save(to url: URL = Self.configURL) -> String? {
        if let error = validationError() { return error }
        do {
            let encoded = try JSONEncoder().encode(self)
            var updated = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            var merged: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: url.path) {
                let old = try Data(contentsOf: url)
                guard let object = try JSONSerialization.jsonObject(with: old) as? [String: Any] else { return "The existing settings file is invalid; it was not replaced." }
                guard let existing = try? JSONDecoder().decode(Config.self,from:old), existing.validationError() == nil else {
                    return "The existing settings file contains invalid values. It was not replaced; repair it in Open config file first."
                }
                if var oldAI = object["ai"] as? [String:Any], let newAI = updated["ai"] as? [String:Any] {
                    for key in ["provider","model","timeoutMs","executable","args","endpoint","apiKeyEnv"] { oldAI.removeValue(forKey:key) }
                    oldAI.merge(newAI) { _, new in new }; updated["ai"] = oldAI
                }
                merged = object
            }
            // Retired second-hotkey settings are ignored during decoding and
            // removed on a successful save, even when old values are malformed.
            // They must never reset or block the user's dictation preferences.
            merged.removeValue(forKey: "commandHotkey")
            merged.removeValue(forKey: "assistant")
            // Remove optional app-owned fields that the new configuration cleared.
            for key in CodingKeys.allCases { merged.removeValue(forKey: key.stringValue) }
            merged.merge(updated) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return nil
        } catch { return "Settings could not be saved. The previous file was retained." }
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

struct Snippet: Codable, Equatable {
    var trigger: String
    var expansion: String
    var isValid: Bool {
        let cleaned = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleaned.isEmpty && cleaned == trigger && trigger.unicodeScalars.count <= 120
            && !trigger.contains("\n") && !trigger.contains("\r")
            && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && expansion.utf8.count <= 8192
            && !trigger.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) || [0x2028,0x2029].contains($0.value) })
            && !expansion.unicodeScalars.contains(where: { ($0.value < 32 || (127...159).contains($0.value)) && ![9,10,13].contains($0.value) })
    }
}

struct AssistantChoice: Codable, Equatable {
    var provider: String
    var model: String
    var effort: String
}
struct AssistantSettings: Codable, Equatable {
    var provider = "inherit"
    var model = "default"
    var effort = "default"
    var timeoutMs = 120000
    enum CodingKeys: String,CodingKey { case provider,model,effort,timeoutMs }
    init() {}
    init(from decoder:Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        provider = try c.decodeIfPresent(String.self,forKey:.provider) ?? "inherit"
        model = try c.decodeIfPresent(String.self,forKey:.model) ?? "default"
        effort = try c.decodeIfPresent(String.self,forKey:.effort) ?? "default"
        timeoutMs = try c.decodeIfPresent(Int.self,forKey:.timeoutMs) ?? 120000
    }
    var isValid: Bool {
        [provider,model,effort].allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) } }
            && (250...180000).contains(timeoutMs)
    }
    var choice: AssistantChoice { .init(provider:provider,model:model,effort:effort) }
    mutating func select(_ choice:AssistantChoice) { provider = choice.provider; model = choice.model; effort = choice.effort }
}
