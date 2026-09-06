import AppKit
import ApplicationServices
import Foundation

@main
struct InsertionTests {
    @MainActor
    static func main() {
        var assertions = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            assertions += 1
            guard value() else { fatalError("FAIL: \(label)") }
        }
        // Synthetic references are only compared, never queried or sent events.
        let field = AXUIElementCreateApplication(1)
        let otherField = AXUIElementCreateApplication(2)
        let window = AXUIElementCreateApplication(3)
        let otherWindow = AXUIElementCreateApplication(4)
        func target(pid: pid_t = 1, element: AXUIElement? = field,
                    window: AXUIElement? = window, document: String? = "test-document",
                    title: String? = "Test") -> FocusedElement.Target {
            .init(pid: pid, element: element, window: window, document: document, windowTitle: title)
        }
        let original = target()
        check(FocusedElement.match(original, target()) == .same, "identical field")
        check(FocusedElement.match(original, target(pid: 2)) == .applicationChanged, "other app")
        check(FocusedElement.match(original, target(element: otherField)) == .fieldChanged, "other field in same app")
        check(FocusedElement.match(original, target(window: otherWindow)) == .windowChanged, "other window")
        check(FocusedElement.match(original, target(document: "second-document")) == .documentChanged, "changed document")
        check(FocusedElement.match(original, target(title: "Other")) == .documentChanged, "changed tab title")
        check(FocusedElement.match(original, target(window: nil)) == .unavailable, "lost window identity")
        check(FocusedElement.match(original, target(element: nil)) == .unavailable, "unavailable current field")
        check(FocusedElement.match(target(element: nil), original) == .unavailable, "unavailable original field")
        check(FocusedElement.match(nil, original) == .unavailable, "no original target")

        let board = NSPasteboard(name: .init("SonaInsertionTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        var current: FocusedElement.Target? = original
        var actions: [@MainActor () -> Void] = []
        var posts: [pid_t] = []
        var postSucceeds = true
        var captureCount = 0
        var switchAfterFirstCheck = false
        let coordinator = InsertionCoordinator(pasteboard: board, currentTarget: {
            captureCount += 1
            if switchAfterFirstCheck && captureCount % 2 == 0 { return target(element: otherField) }
            return current
        }, postPaste: { pid in
            if postSucceeds { posts.append(pid) }
            return postSucceeds
        }, scheduleRestore: { actions.append($0) })
        var pendingNotifications = 0
        coordinator.onPendingChanged = { pendingNotifications += 1 }
        func setString(_ value: String) {
            board.clearContents()
            check(board.setString(value, forType: .string), "private board write")
        }
        func drainRestores() {
            let batch = actions
            actions.removeAll()
            for action in batch { action() }
        }
        func snapshotData() -> [[String: Data]] {
            (board.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.map { ($0.rawValue, item.data(forType: $0)!) })
            }
        }

        // Multiple items and every representation must survive a temporary paste.
        let rich = NSPasteboardItem()
        rich.setString("original", forType: .string)
        rich.setData(Data("{\\rtf1 original}".utf8), forType: .rtf)
        rich.setData(Data([0, 7, 255, 12]), forType: .init("org.sona.test-binary"))
        let file = NSPasteboardItem()
        file.setString("file:///synthetic-test.txt", forType: .fileURL)
        board.clearContents()
        check(board.writeObjects([rich, file]), "multiple original items")
        let saved = snapshotData()
        check(coordinator.insert("first", into: original) == .paste, "same target pastes")
        check(posts == [1], "paste addressed only to captured PID")
        check(board.string(forType: .string) == "first", "temporary dictation clipboard")
        drainRestores()
        check(snapshotData() == saved, "all items and rich/binary representations restored")

        board.clearContents()
        check(coordinator.insert("empty baseline", into: original) == .paste, "empty clipboard paste")
        drainRestores()
        check((board.types ?? []).isEmpty && (board.pasteboardItems ?? []).isEmpty, "empty clipboard restored")

        setString("before")
        check(coordinator.insert("dictation", into: original) == .paste, "paste before user copy")
        setString("user copy")
        drainRestores()
        check(board.string(forType: .string) == "user copy", "new clipboard ownership respected")
        check(coordinator.insert("same text", into: original) == .paste, "paste before identical user copy")
        setString("same text")
        let userCount = board.changeCount
        drainRestores()
        check(board.changeCount == userCount && board.string(forType: .string) == "same text", "identical text still has new ownership")

        setString("rapid baseline")
        check(coordinator.insert("rapid one", into: original) == .paste, "rapid first")
        check(coordinator.insert("rapid two", into: original) == .paste, "rapid second")
        actions.removeFirst()()
        check(board.string(forType: .string) == "rapid two", "old restore cannot replace new dictation")
        drainRestores()
        check(board.string(forType: .string) == "rapid baseline", "rapid pastes restore original baseline")

        let postCount = posts.count
        current = target(element: otherField)
        let untouched = board.changeCount
        check(coordinator.insert("pending field", into: original) == .pending, "field change retains result")
        check(board.changeCount == untouched && posts.count == postCount, "rejected field never touches clipboard or posts")
        current = target(pid: 2)
        check(coordinator.insert("pending app", into: original) == .pending, "app change retains result")
        current = nil
        check(coordinator.insert("pending unknown", into: original) == .pending, "unknown focus retains result")
        current = original
        check(coordinator.insert("pending missing target", into: nil) == .pending, "missing capture retains result")

        captureCount = 0
        switchAfterFirstCheck = true
        check(coordinator.insert("pending race", into: original) == .pending, "field change during clipboard work retained")
        check(board.string(forType: .string) == "rapid baseline" && posts.count == postCount, "second guard restores clipboard before any key")
        switchAfterFirstCheck = false
        postSucceeds = false
        check(coordinator.insert("pending post failure", into: original) == .pending, "event creation failure retained")
        check(board.string(forType: .string) == "rapid baseline", "event failure restores clipboard")
        postSucceeds = true
        check(coordinator.pendingCount == 6 && pendingNotifications == 6, "all pending recordings retained with notifications")
        check(coordinator.hasPendingText, "pending recovery exposed")
        check(coordinator.insert("active paste", into: original) == .paste, "paste before recovery")
        check(coordinator.copyPendingToClipboard(), "explicit recovery succeeds")
        let recovered = "pending field\n\npending app\n\npending unknown\n\npending missing target\n\npending race\n\npending post failure"
        check(board.string(forType: .string) == recovered, "recovery preserves order and content")
        drainRestores()
        check(board.string(forType: .string) == recovered, "manual recovery not undone by delayed restore")
        check(!coordinator.hasPendingText && coordinator.pendingCount == 0 && pendingNotifications == 7, "successful recovery clears pending")
        check(!coordinator.copyPendingToClipboard(), "empty recovery leaves clipboard alone")
        print("PASS: \(assertions) focus and clipboard assertions, no real focus queries, keyboard events, or general clipboard access")
    }
}
