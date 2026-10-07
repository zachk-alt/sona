import AppKit

@MainActor final class MarkerView:NSView {
    var pressed=false { didSet { needsDisplay=true } }
    override func draw(_ dirtyRect:NSRect) {
        (pressed ? NSColor(srgbRed:0.08,green:0.65,blue:0.2,alpha:1)
            : NSColor(srgbRed:0.08,green:0.25,blue:0.8,alpha:1)).setFill()
        bounds.fill()
    }
}

@MainActor final class FixtureDelegate:NSObject,NSApplicationDelegate {
    private var window:NSWindow?
    private var creating=false
    private let marker=MarkerView()
    private var button:NSButton?
    private var count=0
    private var target:Bool { Bundle.main.bundleIdentifier == "dev.sona.qa.target" }
    func applicationDidFinishLaunching(_ notification:Notification) {
        if !target { showWindow() }
        DispatchQueue.main.asyncAfter(deadline:.now()+45) { NSApp.terminate(nil) }
    }
    func applicationDidBecomeActive(_ notification:Notification) {
        guard target, window == nil, !creating else { return }
        creating=true
        DispatchQueue.main.asyncAfter(deadline:.now()+1.2) { self.showWindow() }
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool {
        if let window { window.makeKeyAndOrderFront(nil) }
        return true
    }
    private func showWindow() {
        guard window == nil else { return }
        let frame=NSRect(x:0,y:0,width:640,height:380)
        let created=NSWindow(contentRect:frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window=created; created.isReleasedWhenClosed=false
        created.title=target ? "Sona owned target fixture" : "Sona owned origin fixture"
        marker.frame=frame; marker.autoresizingMask=[.width,.height]; created.contentView=marker
        let field=NSTextField(string:"Owned fixture text")
        field.frame=NSRect(x:24,y:42,width:260,height:28); field.setAccessibilityIdentifier("sona-handoff-field")
        marker.addSubview(field)
        if target {
            let button=NSButton(title:"Mark fixture",target:self,action:#selector(mark))
            self.button=button; button.frame=NSRect(x:24,y:100,width:150,height:32)
            button.setAccessibilityIdentifier("sona-handoff-button"); marker.addSubview(button)
            let status=NSTextField(labelWithString:"target:0")
            status.frame=NSRect(x:24,y:150,width:180,height:25); status.tag=71
            status.setAccessibilityIdentifier("sona-handoff-status"); marker.addSubview(status)
        }
        created.center(); created.makeKeyAndOrderFront(nil); created.makeFirstResponder(field)
        if target && CommandLine.arguments.contains("--late-resize") {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.46) {
                guard let window=self.window else { return }
                var next=window.frame; next.size.width += 48; window.setFrame(next,display:true)
            }
        }
    }
    @objc private func mark() {
        count += 1; marker.pressed=true
        (marker.viewWithTag(71) as? NSTextField)?.stringValue="target:\(count)"
    }
}

@main enum AssistantHandoffFixture {
    @MainActor static func main() {
        let app=NSApplication.shared, delegate=FixtureDelegate()
        app.setActivationPolicy(.regular); app.delegate=delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
