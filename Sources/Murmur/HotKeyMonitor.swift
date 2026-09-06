import CoreGraphics
import AppKit
import Foundation

/// Watches only the configured gesture. Keyboard content is never retained.
final class HotKeyMonitor {
    private let binding: HotKeyBinding
    private var pressedOnTapThread = false
    private lazy var gesture = HotKeyGesture(holdThreshold: NSEvent.doubleClickInterval, handler: handler)

    private(set) var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    private let handler: (HotKeyEvent) -> Bool

    init(binding: HotKeyBinding = HotKeyBinding("right-command")!, handler: @escaping (HotKeyEvent) -> Bool) {
        self.binding = binding
        self.handler = handler
    }

    // MARK: - Lifecycle

    /// Returns false when the tap cannot be created at all. Note that a tap
    /// CAN be created without permission and then never deliver anything, so
    /// callers must check `AXIsProcessTrusted()` separately.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        var mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        if !binding.isModifier {
            mask |= CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // .defaultTap, not .listenOnly. A listen-only KEYBOARD tap is gated
            // by Input Monitoring, and without that grant tapCreate still
            // succeeds and then delivers nothing. A default tap is gated by
            // Accessibility, which the app needs anyway to type text. The event
            // mask limits received events. Only the configured nonmodifier
            // hotkey is consumed; ordinary typing is passed through.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    Log.write("tap: disabled by system, re-enabling")
                    if let refcon,
                       let tap = Unmanaged<HotKeyMonitor>.fromOpaque(refcon).takeUnretainedValue().tap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                if let refcon {
                    let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    if monitor.handle(event, type: type) { return nil }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.tap = tap
        self.runLoopSource = source

        // The tap gets its own thread and run loop. Serviced from the main run
        // loop, the callback is delayed by whatever main is doing, and a stall
        // of a few hundred ms (AVAudioEngine.stop on commit, for one) is enough
        // for the system to disable the tap. All state still lives on main; the
        // callback only ever dispatches there.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let loop = CFRunLoopGetCurrent()
            self?.tapRunLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "murmur.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        self.tapThread = thread
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            if let runLoopSource, let tapRunLoop {
                CFRunLoopRemoveSource(tapRunLoop, runLoopSource, .commonModes)
                CFRunLoopStop(tapRunLoop)
            }
        }
        tap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        pressedOnTapThread = false
        gesture.reset()
    }

    func resetGesture() { gesture.reset() }

    // MARK: - Event handling

    /// Returns true only to consume a configured non-modifier key, so it does
    /// not type a stray character into the target field.
    private func handle(_ event: CGEvent, type: CGEventType) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let now = CFAbsoluteTimeGetCurrent()
        if binding.isModifier {
            guard code == binding.keyCode else {
                if pressedOnTapThread && !binding.matches(flags: event.flags) {
                    DispatchQueue.main.async { [weak self] in self?.gesture.invalidate() }
                }
                return false
            }
            let down = event.flags.rawValue & binding.deviceFlag! != 0
            if down && binding.matches(flags: event.flags) {
                guard !pressedOnTapThread else { return false }
                pressedOnTapThread = true
                DispatchQueue.main.async { [weak self] in self?.gesture.press(at: now) }
            } else if !down && pressedOnTapThread {
                pressedOnTapThread = false
                // Timing only, not the identity or content of another key.
                let lastKey = now - CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.gesture.release(at: now, otherKey: self.gesture.pressedAt.map { lastKey > $0 } ?? false)
                }
            }
            return false
        }
        if type == .keyDown && code == binding.keyCode {
            if pressedOnTapThread { return true }
            guard binding.matches(flags: event.flags), event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
            pressedOnTapThread = true
            DispatchQueue.main.async { [weak self] in self?.gesture.press(at: now) }
            return true
        }
        if type == .keyUp && code == binding.keyCode && pressedOnTapThread {
            pressedOnTapThread = false
            DispatchQueue.main.async { [weak self] in self?.gesture.release(at: now) }
            return true
        }
        if type == .keyDown && pressedOnTapThread {
            DispatchQueue.main.async { [weak self] in self?.gesture.invalidate() }
        }
        return false
    }
}
