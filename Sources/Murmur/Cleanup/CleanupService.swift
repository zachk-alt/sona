import Foundation

/// How hard the cleanup pass is allowed to work on a transcript.
enum CleanupMode {
    /// Default. Wispr Flow behaviour: repair, punctuate, drop filler.
    case prose
    /// Terminal, editor, IDE. Repair obvious mishearings and nothing else,
    /// so a dictated command is never "improved" into something that no
    /// longer runs.
    case strict
}

enum CleanupError: Error {
    case unavailable(String)
    case timedOut
    case badResponse(String)
}
