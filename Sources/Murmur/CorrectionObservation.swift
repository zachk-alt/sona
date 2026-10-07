import AppKit
import ApplicationServices

/// Pure ownership ledger. Only an initially empty field with a verified insertion
/// can enter this scope. Reads are authorized by a local edit witness, not by a
/// bare value notification or by blindly reusing the old range after deletion.
struct CorrectionScope {
    enum Key { case text, backwardDelete, forwardDelete, selection, unsafe }
    let original: String
    private(set) var current: String
    private(set) var selection: NSRange
    let expiresAt: Double
    private(set) var alive = true
    private var pending: (range:NSRange,key:Key,time:Double)?
    private var continuationEnd: Int?
    init(text:String,now:Double) {
        original = text; current = text; selection = NSRange(location:text.utf16.count,length:0); expiresAt = now + 15
    }
    mutating func stop() { alive = false; pending = nil; continuationEnd = nil }
    mutating func noteSelection(_ range:NSRange,count:Int,now:Double) -> Bool {
        guard alive, now < expiresAt, count == current.utf16.count,
              range.location >= 0, range.length >= 0, range.location <= count - range.length else { stop(); return false }
        if range != selection { continuationEnd = nil }
        selection = range; return true
    }
    mutating func key(_ key:Key,now:Double) {
        guard alive, now < expiresAt else { stop(); return }
        guard key != .unsafe else { stop(); return }
        if key == .selection { pending = nil; continuationEnd = nil; return }
        let count = current.utf16.count
        // Appending independently after the insertion is not a correction.
        guard selection.length > 0 || (selection.location > 0 && selection.location < count)
                || continuationEnd == selection.location else { stop(); return }
        pending = (selection,key,now)
    }
    /// Metadata only. A mismatch ends ownership before any text fetch.
    mutating func permittedRead(count:Int,caret:NSRange,now:Double) -> NSRange? {
        guard alive, now < expiresAt, let pending, now - pending.time <= 0.35,
              count >= 0, count <= 4096, caret.length == 0 else { stop(); return nil }
        let oldCount = current.utf16.count
        let removed: Int
        let location: Int
        if pending.range.length > 0 { removed = pending.range.length; location = pending.range.location }
        else if pending.key == .backwardDelete {
            removed = oldCount - count; location = pending.range.location - removed
            guard removed > 0, removed <= 16, location >= 0 else { stop(); return nil }
        } else if pending.key == .forwardDelete {
            removed = oldCount - count; location = pending.range.location
            guard removed > 0, removed <= 16, location + removed <= oldCount else { stop(); return nil }
        } else { removed = 0; location = pending.range.location }
        let added = count - (oldCount - removed)
        guard added >= 0, added <= 16, (pending.key == .text || added == 0),
              caret.location == location + added else { stop(); return nil }
        return NSRange(location:0,length:count)
    }
    mutating func accept(_ text:String,range:NSRange,caret:NSRange,now:Double) -> Bool {
        guard let pending, permittedRead(count:text.utf16.count,caret:caret,now:now) == range else { return false }
        let old = current as NSString, next = text as NSString
        let removed = pending.range.length > 0 ? pending.range.length : (pending.key == .text ? 0 : old.length - next.length)
        let start = pending.key == .backwardDelete && pending.range.length == 0 ? pending.range.location - removed : pending.range.location
        let added = next.length - old.length + removed
        guard start >= 0, removed >= 0, added >= 0,
              old.substring(to:start) == next.substring(to:start),
              old.substring(from:start+removed) == next.substring(from:start+added) else { stop(); return false }
        continuationEnd = start + added
        current = text; selection = caret; self.pending = nil; return true
    }
    func candidate() -> String? {
        func words(_ text:String) -> [String] {
            var values:[String] = []
            text.enumerateSubstrings(in:text.startIndex..<text.endIndex,options:.byWords) { word,_,_,_ in if let word { values.append(word) } }
            return values
        }
        let old = words(original), new = words(current)
        guard old.count == new.count else { return nil }
        let changes = zip(old,new).filter { $0 != $1 }
        guard changes.count == 1, let change = changes.first, change.1.utf16.count <= 100,
              change.1.unicodeScalars.allSatisfy({ CharacterSet.letters.union(.nonBaseCharacters).contains($0) || $0 == "'" || $0 == "’" }) else { return nil }
        return change.1
    }
}

@MainActor
final class CorrectionObservation {
    var enabled = false { didSet { if !enabled { stop() } } }
    private(set) var contentReads = 0
    private(set) var observerStarts = 0
    var onSuggestion: ((String)->Void)?
    private var scope: CorrectionScope?
    private var target: FocusedElement.Target?
    private var observer: AXObserver?
    var isObserving: Bool { observer != nil }
    private var inputTap: CFMachPort?
    private var inputSource: CFRunLoopSource?
    private(set) var inputWitnesses = 0
    private(set) var valueNotifications = 0
    private(set) var lastStopReason = "not started"
    private var localInputMonitor: Any?
    private let observesLocalEvents: Bool
    init(observesLocalEvents: Bool = false) { self.observesLocalEvents = observesLocalEvents }
    private var activation: NSObjectProtocol?
    private var expiry: Timer?
    private var offer: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var runningRead = false

    /// Called only when opt-in is enabled and a paste was dispatched. No observer
    /// exists until the exact inserted text and empty-field baseline are verified.
    func verifyAndBegin(text:String,before:SelectionSnapshot) {
        stop()
        guard enabled else { return }
        guard before.contents.isEmpty, before.contents.range.location == 0,
              before.contents.characterCount == 0, !text.isEmpty, text.utf8.count <= 4096,
              let current = FocusedElement.captureTarget(), current.element != nil,
              before.target.activity == current.activity, FocusedElement.match(before.target,current) == .same,
              let element = current.element else { return }
        AXUIElementSetMessagingTimeout(element,0.08)
        guard let metadata = Self.metadata(element), metadata.count == text.utf16.count,
              metadata.range == NSRange(location:text.utf16.count,length:0),
              SelectionSnapshot.isWritable(element) else { return }
        contentReads += 1
        guard SelectionSnapshot.string(element,range:NSRange(location:0,length:text.utf16.count)) == text else { return }
        target = current; scope = CorrectionScope(text:text,now:ProcessInfo.processInfo.systemUptime)
        var created: AXObserver?
        guard AXObserverCreate(current.pid,{ _,_,notification,context in
            guard let context else { return }
            let instance = Unmanaged<CorrectionObservation>.fromOpaque(context).takeUnretainedValue()
            // AX observer is installed exclusively on the main run loop.
            MainActor.assumeIsolated { instance.changed(notification as String) }
        },&created) == .success, let created else { stop(); return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(created,element,kAXValueChangedNotification as CFString,context) == .success,
              AXObserverAddNotification(created,element,kAXSelectedTextChangedNotification as CFString,context) == .success else { stop(); return }
        let appElement = AXUIElementCreateApplication(current.pid)
        AXUIElementSetMessagingTimeout(appElement,0.08)
        guard AXObserverAddNotification(created,appElement,kAXFocusedUIElementChangedNotification as CFString,context) == .success else { stop(); return }
        observer = created; observerStarts += 1
        CFRunLoopAddSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(created),.commonModes)
        // A post-delivery global NSEvent monitor can arrive after AXValueChanged.
        // This default tap returns every event unchanged, but commits a metadata-only
        // pre-edit witness before the editor can receive that event. The tap is
        // restricted to the destination PID, including targeted postToPid events. It exists only
        // for a verified, opted-in scope. A disabled/stalled tap ends ownership.
        let mask = [CGEventType.keyDown,.leftMouseDown,.rightMouseDown,.otherMouseDown]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreateForPid(pid:current.pid,place:.headInsertEventTap,
            options:.defaultTap,eventsOfInterest:mask,callback:{ _,type,event,context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let instance = Unmanaged<CorrectionObservation>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        instance.stop(reason:"input tap disabled")
                    } else if let event = NSEvent(cgEvent:event) { instance.input(event) }
                }
                return Unmanaged.passUnretained(event)
            },userInfo:context), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0) else {
                stop(reason:"input tap unavailable"); return
            }
        inputTap = tap; inputSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
        CGEvent.tapEnable(tap:tap,enable:true)
        if observesLocalEvents {
            localInputMonitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.input(event) }; return event
            }
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        let remaining = max(0,(scope?.expiresAt ?? 0)-ProcessInfo.processInfo.systemUptime)
        guard remaining > 0 else { stop(reason:"deadline expired during setup"); return }
        let timer = Timer(timeInterval:remaining,repeats:false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(reason:"deadline expired") }
        }
        expiry = timer; RunLoop.main.add(timer,forMode:.common)
    }
    func stop(reason:String = "stopped") {
        lastStopReason = reason
        generation &+= 1; scope = nil; offer?.cancel(); offer = nil; target = nil
        expiry?.invalidate(); expiry = nil
        if let inputTap { CGEvent.tapEnable(tap:inputTap,enable:false); CFMachPortInvalidate(inputTap) }
        if let inputSource { CFRunLoopRemoveSource(CFRunLoopGetMain(),inputSource,.commonModes) }
        inputTap = nil; inputSource = nil
        if let localInputMonitor { NSEvent.removeMonitor(localInputMonitor) }; localInputMonitor = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }; activation = nil
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),.commonModes) }; observer = nil
    }
    private func input(_ event:NSEvent) {
        guard let liveScope = scope else { return }
        guard enabled, ProcessInfo.processInfo.systemUptime < liveScope.expiresAt else {
            stop(reason:"deadline expired before input"); return
        }
        if event.type != .keyDown { scope?.key(.selection,now:ProcessInfo.processInfo.systemUptime); return }
        let modifiers = event.modifierFlags.intersection([.command,.control,.option])
        let key:CorrectionScope.Key
        if modifiers == .command && event.keyCode == 0 { key = .selection }
        else if !modifiers.isEmpty || event.isARepeat { key = .unsafe }
        else if [123,124,125,126,115,119].contains(event.keyCode) { key = .selection }
        else if event.keyCode == 51 { key = .backwardDelete }
        else if event.keyCode == 117 { key = .forwardDelete }
        else if [36,48,53,76].contains(event.keyCode) { key = .unsafe }
        else { key = .text }
        guard key != .unsafe else { stop(reason:"unsupported input"); return }
        guard let target, let element = target.element, Self.sameFocusedField(target,deadline:liveScope.expiresAt),
              let metadata = Self.metadata(element,deadline:liveScope.expiresAt), var scope else { stop(reason:"pre-edit metadata unavailable"); return }
        let now = ProcessInfo.processInfo.systemUptime
        // A new key never legitimizes an earlier unobserved edit. Count must still
        // match the last accepted range, and only caret/range metadata is read here.
        guard scope.noteSelection(metadata.range,count:metadata.count,now:now) else {
            stop(reason:"pre-edit ownership changed"); return
        }
        scope.key(key,now:now)
        guard scope.alive else { stop(reason:"input outside owned correction"); return }
        inputWitnesses += 1; self.scope = scope
    }
    private static func sameFocusedField(_ target:FocusedElement.Target,deadline:Double) -> Bool {
        guard ProcessInfo.processInfo.systemUptime < deadline, let original = target.element,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return false }
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app,0.05)
        guard ProcessInfo.processInfo.systemUptime < deadline,
              let focused = SelectionSnapshot.attribute(app,kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(original,focused) else { return false }
        return ProcessInfo.processInfo.systemUptime < deadline && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
    }
    private static func metadata(_ element:AXUIElement,deadline:Double = .infinity) -> (count:Int,range:NSRange)? {
        AXUIElementSetMessagingTimeout(element,0.05)
        guard ProcessInfo.processInfo.systemUptime < deadline,
              let count = (SelectionSnapshot.attribute(element,kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue,
              count >= 0, count <= 4096, ProcessInfo.processInfo.systemUptime < deadline,
              let value = SelectionSnapshot.attribute(element,kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue,.cfRange,&range), range.location >= 0, range.length >= 0,
              range.location <= count - range.length, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return (count,NSRange(location:range.location,length:range.length))
    }
    private func changed(_ notification:String) {
        if notification == kAXFocusedUIElementChangedNotification { stop(reason:"focus notification"); return }
        if notification == kAXValueChangedNotification { valueNotifications += 1 }
        guard !runningRead, var scope, let target, let element = target.element else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now < scope.expiresAt else { stop(); return }
        // Field metadata/text calls use50ms bounds; the existing full identity probe
        // uses 200ms bounds. Deadline/generation checks discard late results and gate
        // every subsequent range read. No background polling worker exists.
        let epoch = generation; runningRead = true; defer { runningRead = false }
        guard let current = FocusedElement.captureTarget(), current.element != nil,
              FocusedElement.match(target,current) == .same, generation == epoch,
              ProcessInfo.processInfo.systemUptime < scope.expiresAt,
              let metadata = Self.metadata(element,deadline:scope.expiresAt) else { stop(reason:"post-edit focus or metadata unavailable"); return }
        if notification == kAXSelectedTextChangedNotification {
            if metadata.count != scope.current.utf16.count { return }
            guard scope.noteSelection(metadata.range,count:metadata.count,now:now) else { stop(reason:"selection ownership changed"); return }
            self.scope = scope; return
        }
        guard let range = scope.permittedRead(count:metadata.count,caret:metadata.range,now:now) else { stop(reason:"value notification without valid edit witness"); return }
        contentReads += 1
        guard enabled, generation == epoch, ProcessInfo.processInfo.systemUptime < scope.expiresAt,
              let text = SelectionSnapshot.string(element,range:range), text.utf8.count <= 4096,
              generation == epoch, ProcessInfo.processInfo.systemUptime < scope.expiresAt,
              let after = Self.metadata(element,deadline:scope.expiresAt), after.count == metadata.count, after.range == metadata.range,
              scope.accept(text,range:range,caret:after.range,now:ProcessInfo.processInfo.systemUptime) else { stop(reason:"edit receipt verification failed"); return }
        self.scope = scope; offer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == epoch, let scope = self.scope,
                  ProcessInfo.processInfo.systemUptime < scope.expiresAt, let candidate = scope.candidate() else { return }
            self.onSuggestion?(candidate)
        }
        offer = item; DispatchQueue.main.asyncAfter(deadline:.now()+0.8,execute:item)
    }
}
