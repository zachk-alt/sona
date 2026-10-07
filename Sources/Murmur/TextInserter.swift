import AppKit
import ApplicationServices
import Foundation

enum InsertMethod: String {
    case paste, accessibility, failed, pending
}

/// Fixed diagnostic codes only. Never attach text, titles, URLs, or field data.
enum InsertionPendingReason: Equatable {
    enum Stage: String { case initial, final }
    case selectionChanged(Stage)
    case targetChanged(Stage, FocusedElement.Match)
    case clipboardUnreadable, clipboardChanged, clipboardWriteFailed, pasteEventFailed

    var diagnosticCode: String {
        switch self {
        case let .selectionChanged(stage): return "selection_\(stage.rawValue)"
        case let .targetChanged(stage, match): return "target_\(stage.rawValue)_\(match.rawValue)"
        case .clipboardUnreadable: return "clipboard_unreadable"
        case .clipboardChanged: return "clipboard_changed"
        case .clipboardWriteFailed: return "clipboard_write_failed"
        case .pasteEventFailed: return "paste_event_failed"
        }
    }
}

/// A dictation can only be pasted into its captured field. Uncertain results
/// stay in memory until the user explicitly copies them from the menu.
@MainActor
enum TextInserter {
    private static let coordinator = InsertionCoordinator(
        pasteboard: .general,
        currentTarget: { FocusedElement.captureTarget() },
        postPaste: postCommandV,
        scheduleRestore: { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { action() }
        })

    static var hasPendingText: Bool { coordinator.hasPendingText }
    static var pendingCount: Int { coordinator.pendingCount }
    static var lastPendingReason: InsertionPendingReason? { coordinator.lastPendingReason }
    static var onPendingChanged: (() -> Void)? {
        get { coordinator.onPendingChanged }
        set { coordinator.onPendingChanged = newValue }
    }

    @discardableResult
    static func insert(_ text: String, into target: FocusedElement.Target? = nil, validateSelection: (() -> Bool)? = nil) -> InsertMethod {
        coordinator.insert(text, into: target, validateSelection: validateSelection)
    }

    @discardableResult
    static func copyPendingToClipboard() -> Bool { coordinator.copyPendingToClipboard() }

    private static let pasteSourceTag = Int64.random(in:1...Int64.max)
    static func isOwnPasteEvent(_ event:NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == pasteSourceTag
    }
    private static func postCommandV(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.setIntegerValueField(.eventSourceUserData,value:pasteSourceTag)
        up.setIntegerValueField(.eventSourceUserData,value:pasteSourceTag)
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Address the captured process, never activate it or send to a new app.
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}

/// Dependencies let tests exercise ownership and focus changes without posting
/// keyboard events, querying real fields, or touching the general pasteboard.
@MainActor
final class InsertionCoordinator {
    private let pasteboard: NSPasteboard
    private let currentTarget: () -> FocusedElement.Target?
    private let postPaste: (pid_t) -> Bool
    private let scheduleRestore: (@escaping @MainActor () -> Void) -> Void
    private let captureClipboard: (NSPasteboard) -> Result<ClipboardSnapshot, ClipboardSnapshot.Failure>
    private var pending: [String] = []
    private var lease: ClipboardLease?
    var onPendingChanged: (() -> Void)?
    var hasPendingText: Bool { !pending.isEmpty }
    var pendingCount: Int { pending.count }
    private(set) var lastPendingReason: InsertionPendingReason?

    private struct ClipboardLease {
        let id = UUID()
        let changeCount: Int
        let original: ClipboardSnapshot
    }

    init(pasteboard: NSPasteboard,
         currentTarget: @escaping () -> FocusedElement.Target?,
         postPaste: @escaping (pid_t) -> Bool,
         scheduleRestore: @escaping (@escaping @MainActor () -> Void) -> Void,
         captureClipboard: @escaping (NSPasteboard) -> Result<ClipboardSnapshot, ClipboardSnapshot.Failure> = ClipboardSnapshot.captureResult) {
        self.pasteboard = pasteboard
        self.currentTarget = currentTarget
        self.postPaste = postPaste
        self.scheduleRestore = scheduleRestore
        self.captureClipboard = captureClipboard
    }

    @discardableResult
    func insert(_ text: String, into target: FocusedElement.Target?, validateSelection: (() -> Bool)? = nil) -> InsertMethod {
        lastPendingReason = nil
        guard !text.isEmpty else { return .paste }
        guard validateSelection?() != false else { return retain(text, reason: .selectionChanged(.initial)) }
        let initialMatch = FocusedElement.match(target, currentTarget())
        guard initialMatch == .same, let target else { return retain(text, reason: .targetChanged(.initial, initialMatch)) }
        let baseline = pasteboard.changeCount
        let original: ClipboardSnapshot
        if let lease, lease.changeCount == baseline {
            // Rapid insertions must restore the user's clipboard, not the prior dictation.
            original = lease.original
        } else {
            switch captureClipboard(pasteboard) {
            case let .success(snapshot): original = snapshot
            case .failure(.unreadable): return retain(text, reason: .clipboardUnreadable)
            case .failure(.changed): return retain(text, reason: .clipboardChanged)
            }
        }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return retain(text, reason: .clipboardWriteFailed) }
        guard pasteboard.changeCount == baseline else { return retain(text, reason: .clipboardChanged) }
        let cleared = pasteboard.clearContents()
        guard pasteboard.changeCount == cleared else {
            original.restore(pasteboard, onlyIfChangeCount: cleared)
            return retain(text, reason: .clipboardChanged)
        }
        guard pasteboard.writeObjects([item]) else {
            original.restore(pasteboard, onlyIfChangeCount: cleared)
            return retain(text, reason: .clipboardWriteFailed)
        }
        let owned = ClipboardLease(changeCount: pasteboard.changeCount, original: original)
        lease = owned
        // Resolving a promised clipboard representation can take time, so recheck.
        guard validateSelection?() != false else {
            restore(owned)
            return retain(text, reason: .selectionChanged(.final))
        }
        let finalMatch = FocusedElement.match(target, currentTarget())
        guard finalMatch == .same else {
            restore(owned)
            return retain(text, reason: .targetChanged(.final, finalMatch))
        }
        guard postPaste(target.pid) else {
            restore(owned)
            return retain(text, reason: .pasteEventFailed)
        }
        scheduleRestore { [weak self] in self?.restore(owned) }
        return .paste
    }

    @discardableResult
    func copyPendingToClipboard() -> Bool {
        guard !pending.isEmpty else { return false }
        let item = NSPasteboardItem()
        guard item.setString(pending.joined(separator: "\n\n"), forType: .string) else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return false }
        // An explicit recovery copy belongs to the user and must not be restored.
        lease = nil
        pending.removeAll()
        onPendingChanged?()
        return true
    }

    private func retain(_ text: String, reason: InsertionPendingReason) -> InsertMethod {
        lastPendingReason = reason
        pending.append(text)
        onPendingChanged?()
        return .pending
    }

    private func restore(_ owned: ClipboardLease) {
        guard lease?.id == owned.id else { return }
        owned.original.restore(pasteboard, onlyIfChangeCount: owned.changeCount)
        lease = nil
    }
}

/// Snapshot every eagerly available representation of every pasteboard item.
/// If a promised representation cannot be read, do not replace the clipboard.
struct ClipboardSnapshot {
    enum Failure: Error { case unreadable, changed }
    struct Representation {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }
    let items: [[Representation]]

    static func capture(_ pasteboard: NSPasteboard) -> ClipboardSnapshot? {
        try? captureResult(pasteboard).get()
    }

    static func captureResult(_ pasteboard: NSPasteboard) -> Result<ClipboardSnapshot, Failure> {
        let baseline = pasteboard.changeCount
        guard let source = pasteboard.pasteboardItems else {
            let empty = (pasteboard.types ?? []).isEmpty
            guard pasteboard.changeCount == baseline else { return .failure(.changed) }
            guard empty else { return .failure(.unreadable) }
            return .success(ClipboardSnapshot(items: []))
        }
        var items: [[Representation]] = []
        for item in source {
            var representations: [Representation] = []
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    return .failure(pasteboard.changeCount == baseline ? .unreadable : .changed)
                }
                representations.append(Representation(type: type, data: data))
            }
            items.append(representations)
        }
        guard pasteboard.changeCount == baseline else { return .failure(.changed) }
        return .success(ClipboardSnapshot(items: items))
    }

    @discardableResult
    func restore(_ pasteboard: NSPasteboard, onlyIfChangeCount expected: Int) -> Bool {
        var copies: [NSPasteboardItem] = []
        for representations in items {
            let item = NSPasteboardItem()
            for representation in representations {
                guard item.setData(representation.data, forType: representation.type) else { return false }
            }
            copies.append(item)
        }
        guard pasteboard.changeCount == expected else { return false }
        pasteboard.clearContents()
        return copies.isEmpty || pasteboard.writeObjects(copies)
    }
}
