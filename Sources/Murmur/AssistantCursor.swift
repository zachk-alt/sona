import AppKit
import QuartzCore

/// A visual action marker only. It never posts events or moves the system cursor.
@MainActor
final class AssistantCursor {
    private static let canvas = CGSize(width: 108, height: 80)
    private static let tip = CGPoint(x: 22, y: 22)

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class PointerView: NSView {
        override var isFlipped: Bool { true }
        var pulse: CGFloat? { didSet { needsDisplay = true } }
        var reduceMotion = false
        private let blue = NSColor(srgbRed: 15 / 255, green: 92 / 255, blue: 216 / 255, alpha: 1)

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let tip = AssistantCursor.tip
            if let pulse {
                let radius: CGFloat = reduceMotion ? 7 : 3 + 12 * (1 - pow(1 - pulse, 3))
                let ring = NSBezierPath(ovalIn: CGRect(x: tip.x - radius, y: tip.y - radius,
                    width: radius * 2, height: radius * 2))
                context.setStrokeColor(blue.withAlphaComponent(0.48 * pow(1 - pulse, 2)).cgColor)
                ring.lineWidth = 1; ring.stroke()
            }

            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by:tip.x,yBy:tip.y)
            transform.concat()
            let size = NSAffineTransform(); size.scale(by:0.82); size.concat()
            if let pulse, !reduceMotion {
                let press = 1 - 0.035 * sin(.pi * min(1, pulse / 0.75))
                let squash = NSAffineTransform(); squash.scale(by:press); squash.concat()
            }
            // Rounded joins keep the small arrow clean at both Retina and 1x.
            // Its tip remains the exact verified action point throughout a pulse.
            let arrow = NSBezierPath()
            arrow.move(to: .zero)
            arrow.curve(to: CGPoint(x: 1.8, y: 25.8), controlPoint1: CGPoint(x: 0.4, y: 7), controlPoint2: CGPoint(x: 1.2, y: 22))
            arrow.curve(to: CGPoint(x: 3.8, y: 26.2), controlPoint1: CGPoint(x: 1.9, y: 27.1), controlPoint2: CGPoint(x: 2.8, y: 27.3))
            arrow.line(to: CGPoint(x: 8.7, y: 20.3))
            arrow.line(to: CGPoint(x: 13.6, y: 29.4))
            arrow.curve(to: CGPoint(x: 15.2, y: 29.9), controlPoint1: CGPoint(x: 14, y: 30.1), controlPoint2: CGPoint(x: 14.6, y: 30.3))
            arrow.line(to: CGPoint(x: 18.2, y: 28.2))
            arrow.curve(to: CGPoint(x: 18.7, y: 26.6), controlPoint1: CGPoint(x: 18.9, y: 27.8), controlPoint2: CGPoint(x: 19.1, y: 27.3))
            arrow.line(to: CGPoint(x: 13.8, y: 17.6))
            arrow.line(to: CGPoint(x: 22, y: 17.8))
            arrow.curve(to: CGPoint(x: 22.8, y: 15.8), controlPoint1: CGPoint(x: 23.5, y: 17.9), controlPoint2: CGPoint(x: 24, y: 16.7))
            arrow.line(to: .zero); arrow.close()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.23)
            shadow.shadowBlurRadius = 3.5; shadow.shadowOffset = CGSize(width: 0, height: -1)
            shadow.set()
            context.setFillColor(blue.cgColor); arrow.fill()
            NSShadow().set()
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.97).cgColor)
            arrow.lineWidth = 1.15; arrow.lineJoinStyle = .round; arrow.stroke()
            NSGraphicsContext.restoreGraphicsState()

            let badge = NSBezierPath(roundedRect: CGRect(x: 45, y: 35, width: 37, height: 18), xRadius: 6, yRadius: 6)
            context.setFillColor(NSColor(srgbRed:0.075,green:0.105,blue:0.17,alpha:0.88).cgColor); badge.fill()
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor); badge.lineWidth = 0.5; badge.stroke()
            ("Sona" as NSString).draw(at: CGPoint(x: 51, y: 37.5), withAttributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .medium), .foregroundColor: NSColor.white
            ])
        }
    }

    /// CADisplayLink retains its target. This intermediary prevents it from
    /// retaining the cursor after its owning action executor has gone away.
    @MainActor private final class FrameTarget: NSObject {
        weak var cursor: AssistantCursor?
        @objc func update(_ link: CADisplayLink) { cursor?.updateFrame() }
    }
    private struct Movement {
        let start: CGPoint
        let destination: CGPoint
        let began: CFTimeInterval
        let duration: CFTimeInterval
    }

    private let panel: Panel
    private let pointer: PointerView
    private let frameTarget = FrameTarget()
    private var displayLink: CADisplayLink?
    private var movement: Movement?
    private var pulseBegan: CFTimeInterval?
    private var currentPoint: CGPoint?
    private var generation = UUID()
    private var animationFailed = false

    init() {
        let frame = CGRect(origin: .zero, size: Self.canvas)
        panel = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pointer = PointerView(frame: frame)
        panel.contentView = pointer
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true; panel.worksWhenModal = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none; panel.isReleasedWhenClosed = false
        panel.setAccessibilityElement(false); pointer.setAccessibilityElement(false)
        frameTarget.cursor = self
    }

    deinit { displayLink?.invalidate() }

    /// Core Graphics and AppKit share the primary display's x origin. Their y
    /// axes are reversed around that display's top, including secondary screens.
    static func appKitPoint(_ point: CGPoint, primaryDisplayTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayTop - point.y)
    }

    /// Zero velocity and acceleration at both ends, without target overshoot.
    static func movementProgress(_ fraction: Double) -> Double {
        let t = max(0, min(1, fraction))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    static func movementDuration(from start: CGPoint, to end: CGPoint, reduceMotion: Bool) -> Double {
        if reduceMotion { return 0 }
        return min(0.32, 0.19 + hypot(end.x - start.x, end.y - start.y) / 4_000)
    }

    private var primaryDisplayTop: CGFloat? {
        NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        })?.frame.maxY
    }

    private func place(_ point: CGPoint) throws {
        guard point.x.isFinite, point.y.isFinite, let top = primaryDisplayTop else { throw CancellationError() }
        let location = Self.appKitPoint(point, primaryDisplayTop: top)
        panel.setFrameOrigin(CGPoint(x: location.x - Self.tip.x, y: location.y - (Self.canvas.height - Self.tip.y)))
        currentPoint = point
    }

    private func startFrames() {
        guard displayLink == nil else { return }
        // AppKit keeps this link synchronized with the display containing the
        // view, including high-refresh displays and moves between screens.
        let link = pointer.displayLink(target: frameTarget, selector: #selector(FrameTarget.update(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func updateFrame() {
        let now = CACurrentMediaTime()
        if let movement {
            let fraction = min(1, max(0, (now - movement.began) / movement.duration))
            let eased = Self.movementProgress(fraction)
            do {
                try place(CGPoint(x: movement.start.x + (movement.destination.x - movement.start.x) * eased,
                    y: movement.start.y + (movement.destination.y - movement.start.y) * eased))
            } catch { animationFailed = true; hide(); return }
            panel.alphaValue = min(1, (now - movement.began) / 0.065)
            if fraction >= 1 { self.movement = nil; panel.alphaValue = 1 }
        }
        if let pulseBegan {
            let progress = min(1, max(0, (now - pulseBegan) / 0.20))
            pointer.pulse = CGFloat(progress)
            if progress >= 1 { self.pulseBegan = nil; pointer.pulse = nil }
        }
        if movement == nil, pulseBegan == nil {
            displayLink?.invalidate(); displayLink = nil
        }
    }

    func move(to point: CGPoint) async throws {
        generation = UUID()
        let token = generation
        pulseBegan = nil; pointer.pulse = nil; movement = nil; animationFailed = false
        pointer.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let start = currentPoint ?? CGEvent(source: nil)?.location ?? point
        let duration = Self.movementDuration(from: start, to: point, reduceMotion: pointer.reduceMotion)
        do {
            try Task.checkCancellation()
            // With Reduce Motion there is no travel, fade or pointer squash.
            try place(duration == 0 ? point : start)
            panel.alphaValue = duration == 0 ? 1 : 0.01
            panel.orderFrontRegardless()
            guard duration > 0 else { return }
            let began = CACurrentMediaTime()
            movement = Movement(start: start, destination: point, began: began, duration: duration)
            startFrames()
            while movement != nil {
                try Task.checkCancellation()
                guard token == generation, CACurrentMediaTime() < began + duration + 0.5 else { throw CancellationError() }
                // Poll only completion/cancellation. Display-linked callbacks,
                // not this sleep, determine the pointer's rendered positions.
                try await Task.sleep(for: .milliseconds(8))
            }
            guard token == generation, !animationFailed else { throw CancellationError() }
        } catch {
            if token == generation { hide() }
            throw error
        }
    }

    /// Call only after the native action returns success, never while awaiting it.
    func applied() {
        guard panel.isVisible else { return }
        pulseBegan = CACurrentMediaTime(); pointer.pulse = 0
        startFrames()
    }

    func hide() {
        generation = UUID(); movement = nil; pulseBegan = nil
        displayLink?.invalidate(); displayLink = nil
        pointer.pulse = nil; panel.orderOut(nil)
    }

    // The explicit owned-window self-test verifies these native properties.
    var isVisible: Bool { panel.isVisible }
    var isInputTransparent: Bool {
        panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain && panel.styleMask.contains(.nonactivatingPanel)
    }
    var isPulsing: Bool { pointer.pulse != nil }
    var screenCaptureRect: CGRect? {
        guard let top = primaryDisplayTop else { return nil }
        let frame = panel.frame
        return CGRect(x:frame.minX,y:top-frame.maxY,width:frame.width,height:frame.height)
    }
}
