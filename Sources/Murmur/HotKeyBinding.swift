import AppKit
import CoreGraphics

/// What the selected shortcut just asked for.
enum HotKeyEvent {
    /// Key went down. Arm capture (the mic opens after a short delay).
    case begin
    /// Held key released after a real interval. Finish and transcribe.
    case commit
    /// Quick tap. Keep recording until the next press.
    case latch
    /// Press while latched. Finish and transcribe.
    case unlatch
    /// A keyboard shortcut: some other key was struck while Command was down.
    /// Nothing to do with dictation. Throw it away.
    case discard
}

/// A physical key with optional modifiers. No typed text is retained.
struct HotKeyBinding: Equatable {
    let name: String
    let keyCode: Int64
    let modifiers: CGEventFlags
    let deviceFlag: UInt64?
    var isModifier: Bool { deviceFlag != nil }

    private static let aliases = ["cmd": "command", "ctrl": "control", "alt": "option", "win": "command", "esc": "escape", "return": "enter"]
    static let modifierFlags: [String: CGEventFlags] = ["command": .maskCommand, "control": .maskControl, "option": .maskAlternate, "shift": .maskShift]
    static let keys: [String: Int64] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,
        "q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,
        "equal":24,"9":25,"7":26,"minus":27,"8":28,"0":29,"right-bracket":30,"o":31,"u":32,"left-bracket":33,
        "i":34,"p":35,"enter":36,"l":37,"j":38,"quote":39,"k":40,"semicolon":41,"backslash":42,"comma":43,
        "slash":44,"n":45,"m":46,"period":47,"tab":48,"space":49,"backtick":50,"backspace":51,"escape":53,
        "f17":64,"keypad-decimal":65,"keypad-multiply":67,"keypad-plus":69,"keypad-clear":71,"keypad-divide":75,
        "keypad-enter":76,"keypad-minus":78,"f18":79,"f19":80,"keypad-equal":81,"keypad-0":82,"keypad-1":83,
        "keypad-2":84,"keypad-3":85,"keypad-4":86,"keypad-5":87,"keypad-6":88,"keypad-7":89,"f20":90,
        "keypad-8":91,"keypad-9":92,"f5":96,"f6":97,"f7":98,"f3":99,"f8":100,"f9":101,"f11":103,
        "f13":105,"f16":106,"f14":107,"f10":109,"f12":111,"f15":113,"home":115,"page-up":116,
        "delete":117,"f4":118,"end":119,"f2":120,"page-down":121,"f1":122,"left":123,"right":124,"down":125,"up":126
    ]
    static let physicalModifiers: [String: (Int64, UInt64, CGEventFlags)] = [
        "left-command": (55,0x8,.maskCommand), "right-command": (54,0x10,.maskCommand),
        "left-shift": (56,0x2,.maskShift), "right-shift": (60,0x4,.maskShift),
        "left-control": (59,0x1,.maskControl), "right-control": (62,0x2000,.maskControl),
        "left-option": (58,0x20,.maskAlternate), "right-option": (61,0x40,.maskAlternate),
        "fn": (63,0x800000,.maskSecondaryFn)
    ]
    static let relevant: CGEventFlags = [.maskCommand,.maskControl,.maskAlternate,.maskShift]

    init?(_ raw: String) {
        var parts = raw.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        parts = parts.map { Self.aliases[$0] ?? $0 }
        var last = parts.removeLast()
        if Self.modifierFlags[last] != nil { last = "left-" + last }
        var flags: CGEventFlags = []
        for part in parts {
            guard let flag = Self.modifierFlags[part], !flags.contains(flag) else { return nil }
            flags.insert(flag)
        }
        if let (code, side, flag) = Self.physicalModifiers[last] {
            guard !flags.contains(flag) else { return nil }
            keyCode = code; deviceFlag = side; flags.insert(flag)
        } else if let code = Self.keys[last] {
            keyCode = code; deviceFlag = nil
        } else { return nil }
        modifiers = flags
        name = (parts + [last]).joined(separator: "+")
    }

    func matches(flags: CGEventFlags) -> Bool {
        flags.intersection(Self.relevant) == modifiers.intersection(Self.relevant)
    }

    static func name(for event: NSEvent) -> String? {
        let code = Int64(event.keyCode)
        let physical = physicalModifiers.first { $0.value.0 == code }
        guard let key = physical?.key ?? keys.first(where: { $0.value == code })?.key else { return nil }
        let own = physical?.value.2 ?? []
        let prefix = ["control","option","shift","command"].filter {
            let flag = modifierFlags[$0]!
            return UInt64(event.modifierFlags.rawValue) & flag.rawValue != 0 && !own.contains(flag)
        }
        return (prefix + [key]).joined(separator: "+")
    }
}

/// Separately testable gesture state. The monitor supplies observed key events.
final class HotKeyGesture {
    private(set) var pressedAt: Double?
    private(set) var latched = false
    private var stoppingLatch = false
    private var invalid = false
    let holdThreshold: Double
    let handler: (HotKeyEvent) -> Bool
    init(holdThreshold: Double = 0.5, handler: @escaping (HotKeyEvent) -> Bool) {
        self.holdThreshold = holdThreshold; self.handler = handler
    }
    func press(at time: Double) {
        guard pressedAt == nil else { return }
        invalid = false
        stoppingLatch = latched
        if latched || handler(.begin) { pressedAt = time }
    }
    func invalidate() { if pressedAt != nil { invalid = true } }
    func release(at time: Double, otherKey: Bool = false) {
        guard let start = pressedAt else { return }
        pressedAt = nil
        if invalid || otherKey {
            if !stoppingLatch { _ = handler(.discard) }
            stoppingLatch = false
            return
        }
        if stoppingLatch {
            stoppingLatch = false; latched = false; _ = handler(.unlatch)
        } else if time - start >= holdThreshold {
            _ = handler(.commit)
        } else {
            latched = handler(.latch)
        }
    }
    func reset() { pressedAt = nil; latched = false; stoppingLatch = false; invalid = false }
}
