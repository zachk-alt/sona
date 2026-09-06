import AppKit
import ApplicationServices
import Foundation

enum InsertMethod: String {
    case paste, accessibility, failed, pending
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
    static var onPendingChanged: (() -> Void)? {
        get { coordinator.onPendingChanged }
        set { coordinator.onPendingChanged = newValue }
    }

    @discardableResult
    static func insert(_ text: String, into target: FocusedElement.Target? = nil) -> InsertMethod {
        coordinator.insert(text, into: target)
    }

    @discardableResult
    static func copyPendingToClipboard() -> Bool { coordinator.copyPendingToClipboard() }

    private static func postCommandV(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
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
    private var pending: [String] = []
    private var lease: ClipboardLease?
    var onPendingChanged: (() -> Void)?
    var hasPendingText: Bool { !pending.isEmpty }
    var pendingCount: Int { pending.count }

    private struct ClipboardLease {
        let id = UUID()
        let changeCount: Int
        let original: ClipboardSnapshot
    }

    init(pasteboard: NSPasteboard,
         currentTarget: @escaping () -> FocusedElement.Target?,
         postPaste: @escaping (pid_t) -> Bool,
         scheduleRestore: @escaping (@escaping @MainActor () -> Void) -> Void) {
        self.pasteboard = pasteboard
        self.currentTarget = currentTarget
        self.postPaste = postPaste
        self.scheduleRestore = scheduleRestore
    }

    @discardableResult
    func insert(_ text: String, into target: FocusedElement.Target?) -> InsertMethod {
        guard !text.isEmpty else { return .paste }
        guard FocusedElement.match(target, currentTarget()) == .same, let target else { return retain(text) }
        let baseline = pasteboard.changeCount
        let original: ClipboardSnapshot
        if let lease, lease.changeCount == baseline {
            // Rapid insertions must restore the user's clipboard, not the prior dictation.
            original = lease.original
        } else {
            guard let snapshot = ClipboardSnapshot.capture(pasteboard) else { return retain(text) }
            original = snapshot
        }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string), pasteboard.changeCount == baseline else { return retain(text) }
        let cleared = pasteboard.clearContents()
        guard pasteboard.changeCount == cleared, pasteboard.writeObjects([item]) else {
            original.restore(pasteboard, onlyIfChangeCount: cleared)
            return retain(text)
        }
        let owned = ClipboardLease(changeCount: pasteboard.changeCount, original: original)
        lease = owned
        // Resolving a promised clipboard representation can take time, so recheck.
        guard FocusedElement.match(target, currentTarget()) == .same, postPaste(target.pid) else {
            restore(owned)
            return retain(text)
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

    private func retain(_ text: String) -> InsertMethod {
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
    struct Representation {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }
    let items: [[Representation]]

    static func capture(_ pasteboard: NSPasteboard) -> ClipboardSnapshot? {
        let baseline = pasteboard.changeCount
        guard let source = pasteboard.pasteboardItems else {
            guard (pasteboard.types ?? []).isEmpty, pasteboard.changeCount == baseline else { return nil }
            return ClipboardSnapshot(items: [])
        }
        var items: [[Representation]] = []
        for item in source {
            var representations: [Representation] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                representations.append(Representation(type: type, data: data))
            }
            items.append(representations)
        }
        guard pasteboard.changeCount == baseline else { return nil }
        return ClipboardSnapshot(items: items)
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
