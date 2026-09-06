import AppKit
import ApplicationServices
import Foundation

// This file must stay SYNCHRONOUS. A single top-level `await` turns the whole
// entry point into an async main, which runs NSApplication.run() inside a Swift
// concurrency Task. In that state the event tap's mach port source is created
// successfully and then never serviced: the hotkey is silently dead while
// every permission check passes. The CLI modes below therefore hop into a Task
// and block on a plain run loop instead of awaiting at top level.

let arguments = CommandLine.arguments

/// Runs an async CLI mode to completion, then exits with its status.
func runCommand(_ body: @escaping () async -> Int32) -> Never {
    Task { exit(await body()) }
    RunLoop.main.run()
    exit(0)
}

if arguments.contains("--configure") {
    func option(_ name:String) -> String? {
        guard let index = arguments.firstIndex(of:name), arguments.indices.contains(index+1) else { return nil }
        return arguments[index+1]
    }
    var config = Config.load()
    if let hotkey = option("--hotkey") {
        guard let binding = HotKeyBinding(hotkey) else { fputs("Invalid hotkey.\n",stderr); exit(1) }
        config.hotkey = binding.name
    }
    if let provider = option("--provider") {
        guard ["auto","none","claude","codex","gemini","kimi","grok","openai","anthropic","opencode","custom"].contains(provider) else { fputs("Unknown provider.\n",stderr); exit(1) }
        config.ai.provider = provider
    }
    if let model = option("--model") { config.ai.model = model }
    if let sound = option("--sound") { config.sound = sound; config.startSound = nil; config.stopSound = nil }
    config.setupComplete = true
    config.save()
    print("Sona configured: hotkey=\(config.hotkey), provider=\(config.ai.provider), model=\(config.ai.model)")
    exit(0)
}

if let index = arguments.firstIndex(of: "--export-cues"), arguments.indices.contains(index+2) {
    do { try Cue().export(choice:arguments[index+1], directory:URL(fileURLWithPath:arguments[index+2])); exit(0) }
    catch { fputs("Cue export failed.\n",stderr); exit(1) }
}
if let index = arguments.firstIndex(of: "--validate-hotkey") {
    guard arguments.indices.contains(index + 1), let binding = HotKeyBinding(arguments[index + 1]) else {
        fputs("Invalid hotkey. Examples: right-command, option+space, f8.\n", stderr); exit(1)
    }
    print(binding.name); exit(0)
}
if arguments.contains("--prepare-speech") {
    runCommand {
        do { try await AppleTranscriber().installAssets(); print("Speech assets ready."); return 0 }
        catch { fputs("Speech assets unavailable. Connect to the internet and retry --prepare-speech.\n", stderr); return 1 }
    }
}

// Install maintenance only: no application state, microphone, or hotkey.
if arguments.contains("--refresh-login-item") {
    do {
        if try LoginItem.refreshRegistrationIfEnabled() {
            print("login-item: refreshed \(Bundle.main.bundleURL.path)")
        } else {
            print("login-item: unchanged; not currently enabled")
        }
        exit(0)
    } catch {
        fputs("login-item: failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

// Headless pipeline check, usable before any permission is granted.
if arguments.contains("--selftest") {
    let file = arguments.last.flatMap { $0.hasSuffix(".wav") ? $0 : nil }
    runCommand { await SelfTest.run(path: file) }
}

if arguments.contains("--doctor") {
    runCommand { await Doctor.run() }
}

// Tap probe: same bundle, same signature, same launch path as the real app,
// with a bare run loop. Logs every right-Command event it sees for 8 seconds.
if arguments.contains("--taptest") {
    Log.write("taptest: AX=\(AXIsProcessTrusted())")
    let probe = HotKeyMonitor { event in Log.write("taptest: EVENT \(event)"); return true }
    Log.write("taptest: tapCreate=\(probe.start())")
    Thread.sleep(forTimeInterval: 8)
    Log.write("taptest: done")
    exit(0)
}

/// Panel preview: the recording panel with a synthetic voice, for a set
/// number of seconds, no hotkey and no mic. Prints the panel's screen rect
/// in `screencapture -R` form so the look can be checked from a script.
final class StripeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        NSColor.black.setFill()
        // Diagonal stripes on the left half, horizontal text lines on the right.
        let half = bounds.width / 2
        var x: CGFloat = -bounds.height
        while x < half {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: 0)); p.line(to: NSPoint(x: x + 5, y: 0))
            p.line(to: NSPoint(x: x + 5 + bounds.height, y: bounds.height))
            p.line(to: NSPoint(x: x + bounds.height, y: bounds.height)); p.close()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: half, height: bounds.height)).addClip()
            p.fill()
            x += 12
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]
        var y = bounds.height - 16
        while y > 0 {
            NSAttributedString(string: "refraction test line 0123456789 abcdefghij", attributes: attrs)
                .draw(at: NSPoint(x: half + 6, y: y))
            y -= 15
        }
    }
}

final class PanelPreview: NSObject, NSApplicationDelegate {
    let seconds: Double
    let previewsProcessing: Bool
    private var bar: StatusBarController?
    private var backdrop: NSWindow?
    private var clock = 0.0
    init(seconds: Double, previewsProcessing: Bool = false) {
        self.seconds = seconds
        self.previewsProcessing = previewsProcessing
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bar = StatusBarController()
        self.bar = bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            bar.showRecording()
            let frame = bar.panelScreenFrame
            let top = NSScreen.screens.first?.frame.height ?? 0
            print("panel: rect \(Int(frame.minX)),\(Int(top - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))")
            fflush(stdout)
            // MURMUR_BACKDROP=1: a striped window behind the panel, so the
            // glass has something to bend when judging refraction.
            if ProcessInfo.processInfo.environment["MURMUR_BACKDROP"] != nil {
                let w = NSWindow(contentRect: frame.insetBy(dx: -40, dy: -40),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
                w.level = .floating
                w.contentView = StripeView(frame: NSRect(origin: .zero, size: w.frame.size))
                w.orderFrontRegardless()
                bar.showRecording()   // back on top
                self.backdrop = w
            }
            let timer = Timer(timeInterval: 0.1, repeats: true) { [self] _ in
                clock += 0.1
                let n = AudioCapture.bandCount
                var bands = [Float](repeating: 0, count: n)
                for b in 0..<n {
                    let x = Double(b) / Double(n)
                    let v = 0.45 + 0.3 * sin(clock * 2.6 + x * 9) + 0.2 * sin(clock * 6.1 + x * 23) - 0.25 * x
                    bands[b] = Float(max(0.05, min(1, v)))
                }
                bar.setSpectrum(bands)
            }
            RunLoop.main.add(timer, forMode: .common)
            if previewsProcessing {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds * 0.4) {
                    bar.showProcessing()
                    print("panel: processing")
                    fflush(stdout)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                timer.invalidate()
                bar.showIdle()
                print("panel: dismissing")
                fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            }
        }
    }
}

if let flag = arguments.firstIndex(of: "--panel") {
    let seconds = arguments.indices.contains(flag + 1) ? (Double(arguments[flag + 1]) ?? 6) : 6
    let app = NSApplication.shared
    // A preview-only override for comparing materials without changing macOS.
    switch ProcessInfo.processInfo.environment["MURMUR_APPEARANCE"] {
    case "light": app.appearance = NSAppearance(named: .aqua)
    case "dark": app.appearance = NSAppearance(named: .darkAqua)
    default: break
    }
    let preview = PanelPreview(seconds: seconds, previewsProcessing: arguments.contains("--processing"))
    app.delegate = preview
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

/// Menu-bar only: no Dock icon, no windows.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        state.start()
        self.state = state
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
