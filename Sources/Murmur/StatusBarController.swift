import AppKit
import Foundation

/// The menu bar item (a static icon), the menu behind it, and the waveform
/// panel that drops down beneath it while recording and processing.
///
/// The panel is a non-activating NSPanel rather than an NSPopover, on purpose:
/// text insertion depends on the focused field staying focused, and a popover
/// can take key status away from whatever app the user is dictating into.
final class StatusBarController {

    private let item: NSStatusItem
    private let wave = WaveView(barWidth: 2, barGap: 2)
    /// #0F5CD8
    private static let ailBlue = NSColor(srgbRed: 15 / 255, green: 92 / 255, blue: 216 / 255, alpha: 1)
    private let idleIcon = StatusBarController.loadIcon("MenuIcon", template: true)
    /// Full-colour blue badge with the figure in white. Thin strokes tinted
    /// blue on a dark menu bar are close to invisible; a badge is not.
    private let recordingIcon = StatusBarController.loadIcon("MenuIconRecording", template: false)
    private let panel: RecordingPanel
    // Joining ordinary Spaces alone does not permit an overlay in another
    // app's full-screen Space or Stage Manager set. Keep recording and loading
    // visible there without activating Sona or making this panel key.
    private static let recordingSpaces: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary,
        .stationary, .ignoresCycle
    ]
    private var currentGlassSize = StatusBarController.glassSize
    private var activityHighlighted = false
    private var reopeningMenu = false
    private var dismissalTimer: Timer?
    private var dismissalOrigin: NSPoint?
    private static let glowMargin: CGFloat = 26
    private static let glassSize = NSSize(width: 300, height: 104)
    private static let glassRadius: CGFloat = 26

    var onQuit: (() -> Void)?
    var onToggleCleanup: (() -> Void)?
    var onToggleLoginItem: (() -> Void)?
    var onSelectSound: ((String) -> Void)?
    var onTextSettings: (() -> Void)?
    var onSuggestSnippets: (() -> Void)?
    var onReviewCorrection: (() -> Void)?
    private var correctionAvailable = false
    private var errorLabel: NSTextField?
    var onChangeHotkey: (() -> Void)?
    var onCopyPending: (() -> Void)?
    private var hasPendingText = false
    private var hotkeyName = "right-command"

    private var soundChoices: [(id: String, title: String)] = []
    private var currentSound = ""

    func setSounds(_ choices: [(id: String, title: String)], current: String) {
        soundChoices = choices
        currentSound = current
        rebuildMenu()
    }


    private(set) var cleanupEnabled = true
    private var backendLabel = "checking..."

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Sona.MenuBar"
        item.behavior = []
        item.isVisible = true
        if let button = item.button {
            button.image = idleIcon
            button.imagePosition = .imageOnly
            button.toolTip = "Sona"
            button.setAccessibilityLabel("Sona")
        }
        panel = Self.makePanel(containing: wave)
        rebuildMenu()
    }

    // MARK: - Icon

    /// Bundled 44px assets shown at 22pt. The idle one is a template so the
    /// system tints it for light and dark menu bars. Falls back to an SF
    /// Symbol if the file is missing.
    private static func loadIcon(_ name: String, template: Bool) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = template
            image.size = NSSize(width: 22, height: 22)
            return image
        }
        let symbol = NSImage(systemSymbolName: template ? "waveform" : "waveform.circle.fill",
                             accessibilityDescription: "Sona")
        symbol?.isTemplate = template
        return symbol
    }

    // MARK: - Recording panel

    /// Where the panel sits on screen, for the --panel preview mode.
    var panelScreenFrame: NSRect { panel.frame }
    var panelWindowNumber: Int { panel.windowNumber }
    var panelGlassSize: NSSize { currentGlassSize }
    var isActivityHighlighted: Bool { activityHighlighted }

    private static func makePanel(containing view: NSView) -> RecordingPanel {
        let ailBlue = Self.ailBlue
        let glassSize = Self.glassSize
        let radius = Self.glassRadius
        let m = glowMargin
        let size = NSSize(width: glassSize.width + 2 * m, height: glassSize.height + 2 * m)
        let panel = RecordingPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // depth is drawn below, where it can be shaped
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = Self.recordingSpaces

        // Content: the spectrum edge to edge, the credit bottom-right.
        let content = NSView(frame: NSRect(origin: .zero, size: glassSize))
        content.wantsLayer = true
        content.autoresizingMask = [.width, .height]
        view.frame = NSRect(x: 0, y: 30, width: glassSize.width, height: glassSize.height - 44)
        view.autoresizingMask = [.width, .height]
        if let wave = view as? WaveView { wave.barColor = ailBlue }
        content.addSubview(view)

        // The brand blue stays exact; the surrounding type follows macOS.
        let credit = RecordingCredit(brandColor: ailBlue)
        let creditWidth = ceil(credit.fittingSize.width)
        credit.frame = NSRect(x: glassSize.width - 16 - creditWidth, y: 8,
                              width: creditWidth, height: 16)
        credit.autoresizingMask = [.minXMargin]

        content.addSubview(credit)

        // Native menu material follows macOS appearance. The desktop still
        // refracts along the inside edge without activating the panel.
        // Keep the bars and credit above both material surfaces.
        let glassFrame = NSRect(x: m, y: m, width: glassSize.width, height: glassSize.height)
        let glass = RecordingGlassView(frame: glassFrame, cornerRadius: radius)
        content.frame = glassFrame

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        let outlinePath = CGPath(roundedRect: glassFrame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let shape = CGPath(roundedRect: CGRect(origin: .zero, size: glassSize),
                           cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Depth. A real drop shadow below (the glass floats) and a faint blue
        // bloom all round (it is lit from within).
        let depth = Self.shadowLayer(outlinePath, bounds: root.bounds, color: .black,
                                    opacity: 0.30, radius: 14, offset: CGSize(width: 0, height: -7))
        let bloom = Self.shadowLayer(outlinePath, bounds: root.bounds, color: ailBlue,
                                    opacity: 0.18, radius: 22, offset: .zero)
        root.layer?.addSublayer(depth); root.layer?.addSublayer(bloom)
        root.addSubview(glass)

        root.addSubview(content)

        // Everything that plays on the surface sits in one overlay above the glass.
        let overlay = RecordingDecorationView(frame: root.bounds)
        overlay.wantsLayer = true
        overlay.autoresizingMask = [.width, .height]

        // Just inside the edge: the band where light bends through the
        // thickness of the glass. Brightest at the edge, gone by ~12pt in.
        let inside = CAShapeLayer()
        inside.frame = glassFrame
        inside.path = shape
        inside.fillColor = nil
        inside.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
        inside.lineWidth = 2
        inside.shadowColor = NSColor.white.cgColor
        inside.shadowOpacity = 0.45
        inside.shadowRadius = 9
        inside.shadowOffset = .zero
        inside.mask = Self.fillMask(shape, size: glassSize)
        overlay.layer?.addSublayer(inside)

        // Rim: light catching the top lip, fading down the sides, with a
        // fainter return along the bottom edge.
        let rim = CAGradientLayer()
        rim.frame = glassFrame
        rim.type = .axial
        rim.startPoint = CGPoint(x: 0.5, y: 1)
        rim.endPoint = CGPoint(x: 0.5, y: 0)
        rim.colors = [NSColor.white.withAlphaComponent(0.6).cgColor,
                      NSColor.white.withAlphaComponent(0.12).cgColor,
                      NSColor.white.withAlphaComponent(0.03).cgColor,
                      NSColor.white.withAlphaComponent(0.18).cgColor]
        rim.locations = [0, 0.35, 0.75, 1]
        rim.mask = Self.outlineMask(glassSize, radius: radius, lineWidth: 1.2)
        overlay.layer?.addSublayer(rim)

        // Lights on the outline: a formation (leader, follower, tail) turning
        // inside a square track whose MASK is the outline stroke, so the
        // outline stays put while the lights run around it. Drawn twice: a
        // sharp core, and a wider blurred halo the lights throw onto the glass.
        let side = ceil((glassSize.width * glassSize.width + glassSize.height * glassSize.height).squareRoot()) + 8
        let trackFrame = CGRect(x: glassFrame.midX - side / 2, y: glassFrame.midY - side / 2, width: side, height: side)
        let outlineInTrack = CGRect(x: glassFrame.minX - trackFrame.minX, y: glassFrame.minY - trackFrame.minY,
                                    width: glassSize.width, height: glassSize.height)
        func trackMask(lineWidth: CGFloat, blur: CGFloat) -> CAShapeLayer {
            let mask = CAShapeLayer()
            mask.frame = CGRect(origin: .zero, size: trackFrame.size)
            mask.path = CGPath(roundedRect: outlineInTrack, cornerWidth: radius, cornerHeight: radius, transform: nil)
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            mask.lineWidth = lineWidth
            if blur > 0 {
                mask.shadowColor = NSColor.white.cgColor
                mask.shadowOpacity = 1
                mask.shadowRadius = blur
                mask.shadowOffset = .zero
            }
            return mask
        }
        let halo = Formation(frame: trackFrame)
        halo.track.opacity = 0.55
        halo.track.mask = trackMask(lineWidth: 2, blur: 5)
        let core = Formation(frame: trackFrame)
        core.track.mask = trackMask(lineWidth: 1.6, blur: 0)
        overlay.layer?.addSublayer(halo.track)
        overlay.layer?.addSublayer(core.track)
        root.addSubview(overlay)

        panel.contentView = root
        panel.formations = [core, halo]
        panel.recordingContent = content
        panel.resizeSurface = { [weak panel] requested in
            guard let panel else { return }
            let size = NSSize(width: requested.width + 2*m, height: requested.height + 2*m)
            let glassFrame = NSRect(x: m, y: m, width: requested.width, height: requested.height)
            let outline = CGPath(roundedRect: glassFrame, cornerWidth: radius, cornerHeight: radius, transform: nil)
            let inner = CGPath(roundedRect: CGRect(origin: .zero, size: requested), cornerWidth: radius, cornerHeight: radius, transform: nil)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            panel.setContentSize(size); root.frame.size = size
            glass.frame = glassFrame; content.frame = glassFrame
            overlay.frame = root.bounds
            for layer in [depth, bloom] { layer.frame = root.bounds; layer.path = outline; layer.shadowPath = outline }
            inside.frame = glassFrame; inside.path = inner; inside.mask = Self.fillMask(inner, size: requested)
            rim.frame = glassFrame; rim.mask = Self.outlineMask(requested, radius: radius, lineWidth: 1.2)
            let side = ceil(hypot(requested.width, requested.height)) + 8
            let track = CGRect(x: glassFrame.midX-side/2, y: glassFrame.midY-side/2, width: side, height: side)
            let trackOutline = CGRect(x: glassFrame.minX-track.minX, y: glassFrame.minY-track.minY, width: requested.width, height: requested.height)
            for (formation, lineWidth, blur) in [(core, CGFloat(1.6), CGFloat(0)), (halo, CGFloat(2), CGFloat(5))] {
                formation.resize(frame: track)
                let mask = CAShapeLayer(); mask.frame = CGRect(origin: .zero, size: track.size)
                mask.path = CGPath(roundedRect: trackOutline, cornerWidth: radius, cornerHeight: radius, transform: nil)
                mask.fillColor = nil; mask.strokeColor = NSColor.white.cgColor; mask.lineWidth = lineWidth
                if blur > 0 { mask.shadowColor = NSColor.white.cgColor; mask.shadowOpacity = 1; mask.shadowRadius = blur; mask.shadowOffset = .zero }
                formation.track.mask = mask
            }
            CATransaction.commit()
        }
        return panel
    }

    /// A layer that draws nothing but its shadow, shaped like the glass.
    private static func shadowLayer(_ path: CGPath, bounds: CGRect, color: NSColor,
                                    opacity: Float, radius: CGFloat, offset: CGSize) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.frame = bounds
        layer.path = path
        layer.fillColor = NSColor.black.withAlphaComponent(0.001).cgColor
        layer.shadowPath = path
        layer.shadowColor = color.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = radius
        layer.shadowOffset = offset
        return layer
    }

    /// The glass outline as a stroke, for masking.
    private static func outlineMask(_ size: NSSize, radius: CGFloat, lineWidth: CGFloat) -> CAShapeLayer {
        let mask = CAShapeLayer()
        mask.frame = CGRect(origin: .zero, size: size)
        mask.path = CGPath(roundedRect: mask.frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        mask.fillColor = nil
        mask.strokeColor = NSColor.white.cgColor
        mask.lineWidth = lineWidth
        return mask
    }

    /// The glass shape filled, for clipping to the inside.
    private static func fillMask(_ path: CGPath, size: NSSize) -> CAShapeLayer {
        let mask = CAShapeLayer()
        mask.frame = CGRect(origin: .zero, size: size)
        mask.path = path
        return mask
    }

    /// One arc of light in a conic gradient: transparent everywhere except a
    /// band centred at 0.71 of the turn, where the colour peaks.
    fileprivate static func arcLight(peak: CGFloat, halfWidth: CGFloat, color: NSColor) -> CAGradientLayer {
        let light = CAGradientLayer()
        light.type = .conic
        light.startPoint = CGPoint(x: 0.5, y: 0.5)
        light.endPoint = CGPoint(x: 0.5, y: 0)
        let clear = color.withAlphaComponent(0).cgColor
        light.colors = [clear, clear,
                        color.withAlphaComponent(peak * 0.3).cgColor,
                        color.withAlphaComponent(peak).cgColor,
                        color.withAlphaComponent(peak * 0.3).cgColor,
                        clear, clear]
        light.locations = arcLocations(halfWidth: halfWidth)
        return light
    }

    fileprivate static func arcLocations(halfWidth w: CGFloat) -> [NSNumber] {
        let c: CGFloat = 0.71
        return [0, c - w, c - w * 0.35, c, c + w * 0.35, c + w, 1].map { NSNumber(value: Double($0)) }
    }

    func showRecording() {
        restoreCompactSurface()
        errorLabel?.removeFromSuperview(); errorLabel = nil; wave.isHidden = false
        cancelDismissal()
        positionSurface()
        activityHighlighted = true
        item.button?.image = recordingIcon
        wave.startAnimating()
        panel.formations?.forEach { $0.stop() }
        // orderFrontRegardless never activates this app, so focus stays in
        // the field the text is about to land in.
        panel.orderFrontRegardless()
    }

    func showError(_ message: String) {
        showRecording()
        wave.isHidden = true
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize:13,weight:.medium); label.alignment = .center
        label.textColor = .labelColor
        label.frame = wave.frame.insetBy(dx:12,dy:12)
        wave.superview?.addSubview(label); errorLabel = label
        DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self, weak label] in
            guard let self, let label, self.errorLabel === label else { return }
            label.removeFromSuperview(); self.errorLabel = nil; self.wave.isHidden = false; self.showIdle()
        }
    }

    func showProcessing() {
        restoreCompactSurface()
        errorLabel?.removeFromSuperview(); errorLabel = nil; wave.isHidden = false
        cancelDismissal()
        positionSurface(); activityHighlighted = true
        item.button?.image = recordingIcon
        wave.startProcessing()
        startLights()
        panel.orderFrontRegardless()
    }

    func showIdle() {
        activityHighlighted = false
        item.button?.image = idleIcon
        guard panel.isVisible else {
            finishDismissal()
            return
        }
        guard dismissalTimer == nil else { return }

        // Let the live glass and loading wave settle toward the menu bar.
        // A new recording cancels this timer, so an old exit cannot hide it.
        let origin = panel.frame.origin
        dismissalOrigin = origin
        let startedAt = CACurrentMediaTime()
        let duration: CFTimeInterval = 0.36
        let lift: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 6
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.dismissalTimer === timer else { return }
            let progress = min(1, max(0, (CACurrentMediaTime() - startedAt) / duration))
            let eased = CGFloat(progress * progress * (3 - 2 * progress))
            self.panel.alphaValue = 1 - eased
            self.panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + lift * eased))
            if progress >= 1 { self.finishDismissal() }
        }
        dismissalTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Hide the owned recording surface without changing focus.
    func suspendSurface() { cancelDismissal(); panel.orderOut(nil) }
    private func restoreCompactSurface() {
        panel.recordingContent?.isHidden = false
        if currentGlassSize != Self.glassSize { panel.resizeSurface?(Self.glassSize); currentGlassSize = Self.glassSize }
    }
    private func positionSurface() {
        let anchor = menuAnchor()
        let size = panel.frame.size
        let displays = NSScreen.screens.compactMap { screen -> AssistantPanelPlacement.Display? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return .init(quartzFrame: CGDisplayBounds(id.uint32Value), frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
        if let origin = AssistantPanelPlacement.recordingOrigin(displays: displays, menuAnchor: anchor,
                fallbackFrame: NSScreen.main?.frame, panelSize: size, glowMargin: Self.glowMargin) {
            panel.setFrameOrigin(origin)
        }
    }

    private func menuAnchor() -> NSRect? {
        guard item.isVisible else { return nil }
        return item.button.flatMap { button in
            button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        }
    }

    /// Opening the app again must remain useful when macOS obscures its icon.
    /// Show the existing menu in screen coordinates without activating Sona
    /// or making the recording panel key.
    func reopenMenu() {
        item.isVisible = true
        item.length = NSStatusItem.squareLength
        item.button?.image = activityHighlighted ? recordingIcon : idleIcon
        guard !reopeningMenu else { return }
        reopeningMenu = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.reopeningMenu = false }
            guard let menu = self.item.menu,
                  let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            let visible = screen.visibleFrame
            let location = NSPoint(x: max(visible.minX + 8, visible.maxX - menu.size.width - 8),
                                   y: visible.maxY - 6)
            menu.popUp(positioning: nil, at: location, in: nil)
        }
    }

    /// Explicit presentation self-test only. No microphone or field access.
    func exerciseHiddenStatusItem(_ verify: () throws -> Void) rethrows {
        let wasVisible = item.isVisible
        item.isVisible = false
        defer { item.isVisible = wasVisible }
        try verify()
    }

    private func cancelDismissal() {
        dismissalTimer?.invalidate()
        dismissalTimer = nil
        if let origin = dismissalOrigin { panel.setFrameOrigin(origin) }
        dismissalOrigin = nil
        panel.alphaValue = 1
    }

    private func finishDismissal() {
        panel.orderOut(nil)
        wave.stopAnimating()
        panel.formations?.forEach { $0.stop() }
        cancelDismissal()
        restoreCompactSurface()
    }

    /// Two lights that never pass each other, on a script written fresh
    /// each time processing begins (see LightScript), so nothing loops.
    private func startLights() {
        guard let formations = panel.formations,
              formations.first?.leader.animation(forKey: "path") == nil else { return }
        let script = LightScript.generate(seconds: 90)
        for f in formations {
            f.track.isHidden = false
            f.leader.add(script.path(script.one), forKey: "path")
            f.follower.add(script.path(script.two), forKey: "path")
            f.tail.add(script.path(script.one), forKey: "path")
            f.tail.add(script.together(), forKey: "together")
        }
    }

    func setLevel(_ level: Float) {
        wave.setLevel(level)
    }

    func setSpectrum(_ bands: [Float]) {
        wave.setSpectrum(bands)
    }

    // MARK: - Menu

    func setBackend(_ label: String) {
        backendLabel = label
        rebuildMenu()
    }

    func setCleanupEnabled(_ enabled: Bool) {
        cleanupEnabled = enabled
        rebuildMenu()
    }

    func refreshMenu() { rebuildMenu() }
    func setPendingText(_ available: Bool) { hasPendingText = available; rebuildMenu() }
    func setCorrectionAvailable(_ value: Bool) { correctionAvailable = value; rebuildMenu() }
    func setHotkey(_ name: String) { hotkeyName = name; rebuildMenu() }
    private func rebuildMenu() {
        let menu = NSMenu()

        for text in ["Tap \(hotkeyName) to start, tap to stop",
                     "Or hold it and talk"] {
            let hint = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(.separator())

        // Naming the backend matters: the user should always know what is
        // rewriting their words, and whether anything is.
        let backend = NSMenuItem(title: "Cleanup: \(backendLabel)", action: nil, keyEquivalent: "")
        backend.isEnabled = false
        menu.addItem(backend)

        let toggle = NSMenuItem(title: cleanupEnabled ? "Disable cleanup" : "Enable cleanup",
                                action: #selector(toggleCleanup), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let login = NSMenuItem(title: "Open at login",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        if !LoginItem.isInStableLocation {
            login.toolTip = "Move Sona.app to /Applications first, or this will break on rebuild."
        }
        menu.addItem(login)

        // One click previews and keeps. The person hearing it picks it.
        let sound = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for choice in soundChoices {
            let entry = NSMenuItem(title: choice.title, action: #selector(pickSound(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice.id
            entry.state = choice.id == currentSound ? .on : .off
            submenu.addItem(entry)
        }
        sound.submenu = submenu
        menu.addItem(sound)

        menu.addItem(.separator())

        let shortcut = NSMenuItem(title: "Change hotkey...", action: #selector(changeHotkey), keyEquivalent: "")
        shortcut.target = self
        menu.addItem(shortcut)

        let textSettings = NSMenuItem(title: "Vocabulary and saved phrases...", action:#selector(openTextSettings),keyEquivalent:"")
        textSettings.target = self; menu.addItem(textSettings)
        if onSuggestSnippets != nil {
            let suggest = NSMenuItem(title: "Suggest saved phrases...", action:#selector(suggestSnippets),keyEquivalent:"")
            suggest.target = self; menu.addItem(suggest)
        }
        if correctionAvailable {
            let review = NSMenuItem(title: "Review spelling suggestion...",action:#selector(reviewCorrection),keyEquivalent:"")
            review.target = self; menu.addItem(review)
        }

        let recovery = NSMenuItem(title: "Copy pending text", action: hasPendingText ? #selector(copyPending) : nil, keyEquivalent: "")
        recovery.target = self
        recovery.isEnabled = hasPendingText
        menu.addItem(recovery)

        let config = NSMenuItem(title: "Open config file...",
                                action: #selector(openConfig), keyEquivalent: "")
        config.target = self
        menu.addItem(config)

        let quit = NSMenuItem(title: "Quit Sona", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    @objc private func openTextSettings() { onTextSettings?() }
    @objc private func suggestSnippets() { onSuggestSnippets?() }
    @objc private func reviewCorrection() { onReviewCorrection?() }
    @objc private func changeHotkey() { onChangeHotkey?() }
    @objc private func copyPending() { onCopyPending?() }
    @objc private func toggleCleanup() { onToggleCleanup?() }
    @objc private func toggleLoginItem() { onToggleLoginItem?() }

    @objc private func pickSound(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        currentSound = id
        onSelectSound?(id)
        rebuildMenu()
    }
    @objc private func quit() { onQuit?() }

    @objc private func openConfig() {
        Config.writeTemplateIfMissing()
        NSWorkspace.shared.open(Config.configURL)
    }
}


/// One set of lights on the outline: a leader, a follower that keeps its
/// distance behind it, and a wide soft tail wrapping both. `track` is static
/// and carries the mask; `group` is what turns.
private final class Formation {
    let track = CALayer()
    let group = CALayer()
    let leader: CAGradientLayer
    let follower: CAGradientLayer
    let tail: CAGradientLayer

    /// Radians. Positive is CLOCKWISE on screen here (measured, not assumed).
    static let baseTurn = 105.0 * Double.pi / 180

    init(frame: CGRect) {
        track.frame = frame
        track.isHidden = true
        group.frame = CGRect(origin: .zero, size: frame.size)
        leader = StatusBarController.arcLight(peak: 1.0, halfWidth: 0.05, color: .white)
        follower = StatusBarController.arcLight(peak: 0.85, halfWidth: 0.05, color: .white)
        tail = StatusBarController.arcLight(peak: 0.5, halfWidth: 0.14,
                                            color: NSColor(srgbRed: 0.72, green: 0.84, blue: 1, alpha: 1))
        for layer in [tail, follower, leader] {
            layer.frame = group.bounds
            group.addSublayer(layer)
        }
        tail.opacity = 0
        // The arc's rest position, measured on screen, is at bearing ~255 deg
        // (left edge). Turn the whole group so the lights meet at the top
        // centre and the bottom centre instead.
        group.transform = CATransform3DMakeRotation(Self.baseTurn, 0, 0, 1)
        track.addSublayer(group)
    }

    func stop() {
        track.isHidden = true
        for layer in [group, leader, follower, tail] { layer.removeAllAnimations() }
    }
    func resize(frame: CGRect) {
        track.frame = frame; group.bounds = CGRect(origin: .zero, size: frame.size)
        group.position = CGPoint(x: frame.width/2, y: frame.height/2)
        for layer in [tail, follower, leader] { layer.frame = group.bounds }
    }
}

/// A choreography for two lights on the outline, as keyframes.
///
/// Every cycle: from wherever they are merged, the two leave in OPPOSITE
/// directions and meet again somewhere else, arriving together. Their
/// distances differ, so their speeds differ. They pause merged, travel a way
/// together (either direction), pause, and go again. Where they meet, which
/// one goes clockwise, how far they travel together and how long each leg
/// takes are all drawn at random inside limits, and the script is rebuilt
/// every time it is needed, so no two processing runs show the same motion. The
/// last cycle brings them home to the top centre so a repeat is seamless.
private struct LightScript {
    private(set) var times: [Double] = [0]
    private(set) var one: [Double] = [0]      // cumulative radians, positive = clockwise on screen
    private(set) var two: [Double] = [0]
    private var timing: [CAMediaTimingFunction] = []
    private var glowTimes: [Double] = [0]
    private var glow: [Double] = [1]
    var total: Double { times.last ?? 0 }

    static func generate(seconds: Double) -> LightScript {
        var s = LightScript()
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        let linear = CAMediaTimingFunction(name: .linear)
        let twoPi = 2 * Double.pi
        var a = 0.0, b = 0.0
        var firstClockwise = true

        func leg(_ dt: Double, _ da: Double, _ db: Double, _ fn: CAMediaTimingFunction) {
            a += da; b += db
            s.times.append(s.total + dt); s.one.append(a); s.two.append(b); s.timing.append(fn)
        }
        func glow(_ v: Double, at t: Double) { s.glowTimes.append(t); s.glow.append(v) }

        while true {
            let homing = s.total >= seconds - 8
            // 1. Split and meet. Light A goes clockwise by delta, B the other
            //    way by the rest of the circle, so they arrive at one place.
            let here = ((a.truncatingRemainder(dividingBy: twoPi)) + twoPi).truncatingRemainder(dividingBy: twoPi)
            var delta = homing ? (twoPi - here).truncatingRemainder(dividingBy: twoPi)
                               : Double.random(in: 0.55 * .pi ... 1.45 * .pi)
            var extra = 0.0
            if homing && delta < 0.5 * .pi { extra = twoPi }      // a full extra lap rather than a shuffle
            if delta == 0 { delta = twoPi; extra = 0 }
            if Bool.random() { firstClockwise.toggle() }
            let (da, db) = firstClockwise ? (delta + extra, -(twoPi - delta))
                                          : (-(twoPi - delta), delta + extra)
            let t1 = Double.random(in: 1.2 ... 2.0)
            glow(0, at: s.total + t1 * 0.25)
            leg(t1, da, db, ease)
            glow(1, at: s.total)
            // 2. Pause, merged.
            leg(Double.random(in: 0.25 ... 0.5), 0, 0, linear)
            if homing { break }
            // 3. Travel together, either way.
            let d = Double.random(in: 0.3 * .pi ... 1.1 * .pi) * (Bool.random() ? 1 : -1)
            leg(Double.random(in: 0.9 ... 1.6), d, d, ease)
            // 4. Pause again.
            leg(Double.random(in: 0.25 ... 0.5), 0, 0, linear)
            glow(1, at: s.total)
        }
        glow(1, at: s.total)
        return s
    }

    func path(_ values: [Double]) -> CAKeyframeAnimation {
        let anim = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        anim.values = values
        anim.keyTimes = times.map { NSNumber(value: $0 / total) }
        anim.timingFunctions = timing
        anim.duration = total
        anim.repeatCount = .infinity
        return anim
    }

    func together() -> CAKeyframeAnimation {
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = glow
        anim.keyTimes = glowTimes.map { NSNumber(value: min(1, $0 / total)) }
        anim.duration = total
        anim.repeatCount = .infinity
        return anim
    }
}

/// Somewhere to hang the formations without more properties on the window.
private var formationsKey = 0
extension NSPanel {
    fileprivate var formations: [Formation]? {
        get { objc_getAssociatedObject(self, &formationsKey) as? [Formation] }
        set { objc_setAssociatedObject(self, &formationsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/// The credit keeps its brand color while its supporting type and shadow
/// respond immediately to Light, Dark, and accessibility appearances.
private final class RecordingCredit: NSTextField {
    private let brandColor: NSColor

    init(brandColor: NSColor) {
        self.brandColor = brandColor
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        wantsLayer = true
        focusRingType = .none
        cell?.usesSingleLineMode = true
        alignment = .right
        updateText()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateText()
    }

    private func updateText() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            let right = NSMutableParagraphStyle()
            right.alignment = .right
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.70 : 0.12)
            shadow.shadowBlurRadius = dark ? 1.5 : 0.5
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            let line = NSMutableAttributedString(
                string: "by ", attributes: [.font: font, .paragraphStyle: right,
                                            .shadow: shadow, .foregroundColor: NSColor.labelColor])
            line.append(NSAttributedString(
                string: "Actual Intelligence Labs",
                attributes: [.font: font, .paragraphStyle: right, .shadow: shadow,
                             .foregroundColor: brandColor]))
            attributedStringValue = line
        }
    }
}

/// Recording must leave the insertion target's keyboard focus untouched.
private final class RecordingPanel: NSPanel {
    var recordingContent: NSView?
    var resizeSurface: ((NSSize) -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class RecordingDecorationView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A native, appearance-aware menu material over the refracting desktop.
/// The active material state affects its look, never the panel's keyboard focus.
private final class RecordingGlassView: NSView {
    private let radius: CGFloat
    private var displayObserver: NSObjectProtocol?

    init(frame: NSRect, cornerRadius: CGFloat) {
        radius = cornerRadius
        super.init(frame: frame)
        updateMaterial()
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.updateMaterial() }
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { updateMaterial() }
    }

    deinit {
        if let displayObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayObserver)
        }
    }

    private func updateMaterial() {
        subviews.forEach { $0.removeFromSuperview() }
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let refraction = reduceTransparency ? nil : NativeRefraction.makeLayer(
            size: bounds.size, cornerRadius: radius)
        if let refraction {
            // This must come first: a menu material underneath would be sampled
            // by the refracting layer and erase the desktop's edge detail.
            refraction.cornerRadius = radius
            refraction.masksToBounds = true
            let host = NSView(frame: bounds)
            host.layer = refraction
            host.wantsLayer = true
            addSubview(host)
        }

        let material = NSVisualEffectView(frame: bounds)
        material.material = .menu
        material.blendingMode = .behindWindow
        material.state = .active
        material.autoresizingMask = [.width, .height]
        material.wantsLayer = true
        material.layer?.cornerRadius = radius
        material.layer?.masksToBounds = true
        if refraction != nil {
            // Native frosting covers the edge and grows toward the body,
            // softening the refracted detail while following macOS appearance.
            material.maskImage = Self.centerMask(size: bounds.size, radius: radius)
        }
        // With Reduce Transparency or unavailable refraction, macOS draws the
        // full native material, including its own accessibility treatment.
        addSubview(material)
    }

    private static func centerMask(size: CGSize, radius: CGFloat) -> NSImage? {
        let scale: CGFloat = 2
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0 else { return nil }
        // Native status panels keep their body material close to the perimeter.
        // Leave only a narrow, softly refracting lip instead of a clear border.
        let feather: CGFloat = 6
        let edgeFrosting: CGFloat = 0.68
        var alpha = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let qx = abs((CGFloat(x) + 0.5) / scale - size.width / 2) - (size.width / 2 - radius)
                let qy = abs((CGFloat(y) + 0.5) / scale - size.height / 2) - (size.height / 2 - radius)
                let dx = max(qx, 0), dy = max(qy, 0)
                let depth = radius - sqrt(dx * dx + dy * dy) - min(max(qx, qy), 0)
                let t = max(0, min(1, depth / feather))
                let bodyBlend = t * t * (3 - 2 * t)
                let coverage = max(0, min(1, depth * scale))
                let opacity = coverage * (edgeFrosting + (1 - edgeFrosting) * bodyBlend)
                alpha[(y * width + x) * 4 + 3] = UInt8((opacity * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(alpha) as CFData),
              let image = CGImage(width: width, height: height,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true,
                  intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: size)
    }
}

/// A desktop-sampling refraction surface using the compositor's glass filter.
/// These classes are private macOS implementation details. A missing class,
/// selector, or filter input returns nil so the caller can retain its fallback.
private enum NativeRefraction {
    static func makeLayer(
        size: CGSize,
        cornerRadius: CGFloat,
        refractionHeight: CGFloat = 10,
        refractionAmount: CGFloat = -12
    ) -> CALayer? {
        guard size.width > 0, size.height > 0,
              size.width.isFinite, size.height.isFinite,
              cornerRadius.isFinite, refractionHeight.isFinite, refractionAmount.isFinite,
              let backdrop = makeObject("CABackdropLayer") as? CALayer,
              let source = makeObject("CASDFLayer") as? CALayer,
              let output = makeObject("CASDFOutputEffect"),
              let shape = makeObject("CASDFElementLayer") as? CALayer,
              let filter = makeFilter("glassBackground") else { return nil }

        let backdropValues: [String: Any] = [
            "windowServerAware": true,
            "allowsInPlaceFiltering": false,
            "captureOnly": false,
            "scale": 1.0
        ]
        let sourceValues: [String: Any] = ["effect": output]
        let outputValues: [String: Any] = ["minimum": -10000.0, "maximum": 100.0]
        let shapeValues: [String: Any] = ["mode": "bounds", "operation": "union"]
        guard supportsSetters(backdrop, for: backdropValues),
              supportsSetters(source, for: sourceValues),
              supportsSetters(output, for: outputValues),
              supportsSetters(shape, for: shapeValues) else { return nil }

        // Match the native source format, with all non-refraction treatments off.
        let clear = NSColor.clear.cgColor
        let filterValues: [String: Any] = [
            "inputSourceSublayerName": "@0",
            "inputInnerRefractionAmount": refractionAmount,
            "inputInnerRefractionHeight": max(0, refractionHeight),
            "inputOuterRefractionAmount": 0.0,
            "inputOuterRefractionHeight": 0.0,
            "inputRefractionDistance0": -1.0,
            "inputRefractionDistance1": -0.5,
            "inputRefractionOpacity": 1.0,
            "inputBlurRadius": 0.0,
            "inputBlurOpacity0": 0.0,
            "inputBlurOpacity1": 0.0,
            "inputBlurOpacity2": 0.0,
            "inputBlurOpacity3": 0.0,
            "inputBlurOpacity4": 0.0,
            "inputBlurDistance0": 0.0,
            "inputBlurDistance1": 0.0,
            "inputBlurDistance2": 0.0,
            "inputBlurDistance3": 0.0,
            "inputBlurDistance4": 0.0,
            "inputFaceOpacity": 0.0,
            "inputFaceColorMatrixWhite": 1.0,
            "inputFaceColorMatrixBlack": 0.0,
            "inputFaceColorMatrixSaturation": 1.0,
            "inputFaceColorMatrixFillColor": clear,
            "inputBleedAmount": 0.0,
            "inputBleedHeight": 0.0,
            "inputBleedBlurRadius": 0.0,
            "inputBleedDistance0": 1.0,
            "inputBleedDistance1": 0.0,
            "inputBleedOpacity": 0.0,
            "inputBleedDarkenBlend": false,
            "inputBleedColorMatrixWhite": 1.0,
            "inputBleedColorMatrixBlack": 0.0,
            "inputBleedColorMatrixSaturation": 1.0,
            "inputBleedColorMatrixFillColor": clear,
            "inputShadowOffset": NSValue(size: .zero),
            "inputShadowAmount": 0.0,
            "inputShadowHeight": 0.0,
            "inputShadowOpacity": 0.0,
            "inputShadowColorMatrixWhite": 1.0,
            "inputShadowColorMatrixBlack": 0.0,
            "inputShadowColorMatrixSaturation": 1.0,
            "inputShadowColorMatrixFillColor": clear,
            "inputShadowDistanceOffset": 0.0,
            "inputShadowBlurRadius": 0.0,
            "inputShadowRadius": 0.0,
            "inputSDRHoldingToneEnabled": false,
            "inputSDRHoldingToneWhite": 1.0,
            "inputSDRGradientDistance0": 0.0,
            "inputSDRGradientDistance1": 0.0,
            "inputSDRShadowOpacity": 0.0,
            "inputMaxHeadroom": 9999.0,
            "inputShadowVibrancyContribution": 0.0,
            "inputClamp": 1.0,
            "inputClampPreserveHue": false
        ]
        guard filter.responds(to: NSSelectorFromString("inputKeys")),
              let keys = filter.value(forKey: "inputKeys") as? [String],
              Set(keys).isSuperset(of: filterValues.keys) else { return nil }

        for (key, value) in backdropValues { backdrop.setValue(value, forKey: key) }
        for (key, value) in sourceValues { source.setValue(value, forKey: key) }
        for (key, value) in outputValues { output.setValue(value, forKey: key) }
        for (key, value) in shapeValues { shape.setValue(value, forKey: key) }
        for (key, value) in filterValues { filter.setValue(value, forKey: key) }

        let bounds = CGRect(origin: .zero, size: size)
        backdrop.anchorPoint = .zero
        backdrop.frame = bounds
        backdrop.name = "@0"
        backdrop.filters = [filter]

        source.anchorPoint = .zero
        source.frame = bounds
        source.name = "@0"
        let group = CALayer()
        // Native glass keeps the shape in a zero-sized container at the origin.
        group.anchorPoint = .zero
        group.frame = .zero
        shape.anchorPoint = .zero
        shape.frame = bounds
        shape.cornerRadius = min(max(0, cornerRadius), min(size.width, size.height) / 2)
        shape.cornerCurve = .circular
        group.addSublayer(shape)
        source.addSublayer(group)
        backdrop.addSublayer(source)
        return backdrop
    }

    private static func supportsSetters(_ object: NSObject, for values: [String: Any]) -> Bool {
        values.keys.allSatisfy { key in
            let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
            return object.responds(to: NSSelectorFromString(setter))
        }
    }

    private static func makeObject(_ name: String) -> NSObject? {
        guard let type = NSClassFromString(name),
              let method = class_getClassMethod(type, NSSelectorFromString("new")) else { return nil }
        typealias Create = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let create = unsafeBitCast(method_getImplementation(method), to: Create.self)
        return create(type, NSSelectorFromString("new"))?.takeRetainedValue() as? NSObject
    }

    private static func makeFilter(_ name: String) -> NSObject? {
        guard let type = NSClassFromString("CAFilter"),
              let typesMethod = class_getClassMethod(type, NSSelectorFromString("filterTypes")),
              let makeMethod = class_getClassMethod(type, NSSelectorFromString("filterWithType:")) else { return nil }
        typealias ReadTypes = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let readTypes = unsafeBitCast(method_getImplementation(typesMethod), to: ReadTypes.self)
        guard let types = readTypes(type, NSSelectorFromString("filterTypes"))?.takeUnretainedValue() as? [String],
              types.contains(name) else { return nil }
        typealias MakeFilter = @convention(c) (AnyClass, Selector, NSString) -> Unmanaged<AnyObject>?
        let make = unsafeBitCast(method_getImplementation(makeMethod), to: MakeFilter.self)
        return make(type, NSSelectorFromString("filterWithType:"), name as NSString)?.takeUnretainedValue() as? NSObject
    }
}
