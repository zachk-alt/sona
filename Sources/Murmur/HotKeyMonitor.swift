import CoreGraphics
import AppKit
import Foundation

/// Watches only the configured gesture. Keyboard content is never retained.
final class HotKeyMonitor {
    private let router: HotKeyRouter
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private let handler: (HotKeyEvent) -> Bool
    private(set) var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    init(binding: HotKeyBinding = HotKeyBinding("right-command")!, handler: @escaping (HotKeyEvent) -> Bool) {
        router = HotKeyRouter(binding: binding, threshold: NSEvent.doubleClickInterval)
        self.handler = handler
    }

    // MARK: - Lifecycle

    /// Returns false when the tap cannot be created at all. Note that a tap
    /// CAN be created without permission and then never deliver anything, so
    /// callers must check `AXIsProcessTrusted()` separately.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
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
                    Log.write("tap: disabled by system, cancelling stale gestures")
                    if let refcon {
                        let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                        monitor.resetGesture()
                        DispatchQueue.main.async { [weak monitor] in
                            _ = monitor?.handler(.discard)
                        }
                    }
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
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            self.tapRunLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            // The C event callback carries an unretained context pointer.
            // Keep it alive until invalidation has drained this run loop,
            // including a final system-disabled callback during teardown.
            withExtendedLifetime(self) { CFRunLoopRun() }
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
        resetGesture()
    }

    func resetGesture() {
        stateLock.lock(); generation &+= 1; router.reset(); stateLock.unlock()
    }

    private func handle(_ event: CGEvent, type: CGEventType) -> Bool {
        stateLock.lock()
        let epoch = generation
        let result = router.route(type: type, code: event.getIntegerValueField(.keyboardEventKeycode),
                                  flags: event.flags, repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                  time: ProcessInfo.processInfo.systemUptime)
        enqueue(result, epoch: epoch)
        stateLock.unlock()
        return result.consumed
    }

    /// Enqueued while locked so physical presses and releases retain their
    /// order even if the main thread is briefly busy.
    private func enqueue(_ result: HotKeyRoute, epoch: UInt64) {
        if !result.events.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for action in result.events {
                    self.stateLock.lock(); let current = self.generation == epoch; self.stateLock.unlock()
                    guard current else { return }
                    if !self.handler(action) {
                        self.stateLock.lock(); self.router.reset(); self.stateLock.unlock()
                        return
                    }
                }
            }
        }
    }
}
