import CoreGraphics

/// The event tap and standalone tests share this single dictation router.
/// Only physical held-key state is retained, never characters or a key history.
struct HotKeyRoute {
    var consumed = false
    var events: [HotKeyEvent] = []
}
final class HotKeyRouter {
    private let binding: HotKeyBinding
    private var pressedAt: Double?
    private var invalid = false
    private var latched = false
    private var stopping = false
    private var heldKeys: Set<Int64> = []
    let threshold: Double

    init(binding: HotKeyBinding, threshold: Double = 0.5) {
        self.binding = binding
        self.threshold = threshold
    }
    func reset() {
        heldKeys.removeAll()
        pressedAt = nil; invalid = false; latched = false; stopping = false
    }
    func route(type: CGEventType, code: Int64, flags: CGEventFlags, repeatKey: Bool = false, time: Double) -> HotKeyRoute {
        var output = HotKeyRoute()
        let previouslyHeld = heldKeys
        if type == .keyDown { heldKeys.insert(code) }
        if type == .keyUp { heldKeys.remove(code) }
        let own = code == binding.keyCode
        let down = binding.isModifier ? (type == .flagsChanged && own && flags.rawValue & binding.deviceFlag! != 0) : (type == .keyDown && own)
        let up = binding.isModifier ? (type == .flagsChanged && own && flags.rawValue & binding.deviceFlag! == 0) : (type == .keyUp && own)
        // A same-family opposite physical modifier is still a chord.
        let family = HotKeyBinding.physicalModifiers.values.first { $0.0 == binding.keyCode }?.2
        let oppositeHeld = family.map { family in
            HotKeyBinding.physicalModifiers.values.contains { $0.0 != binding.keyCode && $0.2 == family && flags.rawValue & $0.1 != 0 }
        } ?? false
        let clean = binding.matches(flags: flags) && !oppositeHeld
        if pressedAt != nil && ((type == .keyDown && !own) || (type == .flagsChanged && !up && !clean)) {
            if !invalid && !stopping { output.events.append(.discard) }
            invalid = true
        }
        if down {
            if pressedAt != nil {
                if !binding.isModifier { output.consumed = true }
                return output
            }
            guard !repeatKey, clean, previouslyHeld.subtracting([code]).isEmpty else { return output }
            pressedAt = time; invalid = false; stopping = latched
            if !binding.isModifier { output.consumed = true }
            if !latched { output.events.append(.begin) }
        } else if up, let start = pressedAt {
            if !binding.isModifier { output.consumed = true }
            pressedAt = nil
            guard !invalid else { stopping = false; return output }
            if stopping {
                stopping = false; latched = false
                output.events.append(.unlatch)
            } else if time - start >= threshold {
                output.events.append(.commit)
            } else {
                latched = true
                output.events.append(.latch)
            }
        }
        return output
    }
}
