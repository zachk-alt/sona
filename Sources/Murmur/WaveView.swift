import AppKit
import Foundation

/// The live recording spectrum and travelling processing wave.
///
/// Plain AppKit drawing, deliberately not SwiftUI: an NSHostingView inside a
/// status item reproduces a known macOS 26 stutter, while this measured a
/// clean 60 fps with zero dropped frames at 2.9% of one core.
///
/// Each bar tracks its own frequency band, low on the left, high on the
/// right, so different parts of the voice light different bars. Bands arrive
/// at ~10 Hz and each bar eases toward its target every frame: fast up, slow
/// down, with a little per-bar variation so nothing moves in lockstep.
final class WaveView: NSView {

    private let barWidth: CGFloat
    private let barGap: CGFloat

    private var targets = [CGFloat](repeating: 0, count: AudioCapture.bandCount)
    private var current = [CGFloat](repeating: 0, count: AudioCapture.bandCount)
    private var phase: CGFloat = 0
    private var timer: Timer?
    private enum Mode { case idle, recording, processing }
    private var mode = Mode.idle
    private var processingStartedAt: CFTimeInterval = 0

    var barColor: NSColor = .labelColor

    private var isIdle: Bool { mode == .idle }

    init(barCount: Int = 0, barWidth: CGFloat = 2, barGap: CGFloat = 2) {
        self.barWidth = barWidth
        self.barGap = barGap
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Kept for callers that only have a loudness number.
    func setLevel(_ value: Float) {}

    func setSpectrum(_ bands: [Float]) {
        guard mode == .recording, bands.count == targets.count else { return }
        for i in 0..<bands.count { targets[i] = CGFloat(bands[i]) }
    }

    func startAnimating() {
        mode = .recording
        startTimer()
        needsDisplay = true
    }

    func startProcessing() {
        mode = .processing
        processingStartedAt = CACurrentMediaTime()
        startTimer()
        needsDisplay = true
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common so the animation survives menu tracking and window drags.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
        for i in 0..<targets.count { targets[i] = 0; current[i] = 0 }
        mode = .idle
        phase = 0
        needsDisplay = true
    }

    private var barCount: Int {
        max(3, Int(bounds.width / (barWidth + barGap)))
    }

    private func tick() {
        if mode == .processing {
            let elapsed = CGFloat(CACurrentMediaTime() - processingStartedAt)
            for i in 0..<targets.count {
                let x = CGFloat(i) / CGFloat(max(1, targets.count - 1))
                let crest = 0.5 + 0.5 * sin(x * .pi * 3.2 - elapsed * 4.2)
                targets[i] = 0.10 + 0.52 * crest * crest
            }
        }
        for i in 0..<current.count {
            // Slightly different rates per band so neighbours do not move as one.
            let up: CGFloat = 0.45 + 0.15 * CGFloat(i % 3) / 2
            let down: CGFloat = 0.10 + 0.06 * CGFloat((i * 7) % 5) / 4
            let rate = targets[i] > current[i] ? up : down
            current[i] += (targets[i] - current[i]) * rate
        }
        phase += 0.14
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = barCount
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * barGap
        var x = (bounds.width - totalWidth) / 2
        let minHeight: CGFloat = 2
        let maxHeight = bounds.height - 2

        if !isIdle {
            let shadow = NSShadow()
            shadow.shadowColor = barColor.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 5
            shadow.shadowOffset = .zero
            shadow.set()
        }

        for i in 0..<count {
            // Map bar -> band with linear interpolation between neighbours.
            let position = CGFloat(i) / CGFloat(max(1, count - 1)) * CGFloat(current.count - 1)
            let lo = Int(position), hi = min(lo + 1, current.count - 1)
            let frac = position - CGFloat(lo)
            let level = current[lo] * (1 - frac) + current[hi] * frac

            let shimmer: CGFloat = mode == .processing
                ? 1 : 0.9 + 0.1 * (sin(phase + CGFloat(i) * 0.7) * 0.5 + 0.5)
            let height = isIdle
                ? minHeight
                : max(minHeight, minHeight + level * shimmer * (maxHeight - minHeight))
            let alpha = isIdle ? 0.3 : (0.55 + 0.45 * min(1, level * 1.6))

            barColor.withAlphaComponent(alpha).setFill()
            let rect = NSRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + barGap
        }
    }
}
