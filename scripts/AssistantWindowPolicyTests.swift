import Foundation
import CoreGraphics

@main
struct AssistantWindowPolicyTests {
    static func main() {
        var count = 0
        func check(_ condition:Bool,_ description:String) {
            precondition(condition,description); count += 1
        }
        check(AssistantBrowserPolicy.route(bundleID:"com.google.Chrome",declaredSchemes:["http","https"]) == .current,"Chrome retains URL routing")
        check(AssistantBrowserPolicy.route(bundleID:"com.apple.Safari",declaredSchemes:["HTTP","HTTPS"]) == .current,"Safari metadata is case insensitive")
        check(AssistantBrowserPolicy.route(bundleID:"com.google.Chrome",declaredSchemes:["https"]) == .refuse,"Unverified current browser must not fall back")
        check(AssistantBrowserPolicy.route(bundleID:"com.example.Editor",declaredSchemes:[]) == .systemDefault,"Non-browser may use system default")
        check(AssistantBrowserPolicy.route(bundleID:"com.example.Editor",declaredSchemes:["http","https"]) == .refuse,"Unknown web handler never silently switches browsers")
        check(AssistantClickPolicy.canPress(role:"AXButton",advertised:[],enabled:true),"Maps button can attempt unadvertised AXPress")
        check(AssistantClickPolicy.canPress(role:"AXRadioButton",advertised:["AXShowMenu"],enabled:true),"Maps transport can attempt unadvertised AXPress")
        check(!AssistantClickPolicy.canPress(role:"AXButton",advertised:["AXPress"],enabled:false),"Disabled control never receives an action")
        check(!AssistantClickPolicy.canPress(role:"AXButton",advertised:[],enabled:nil),"Unadvertised control requires proven enabled state")
        check(!AssistantClickPolicy.canPress(role:"AXGroup",advertised:[],enabled:true),"Generic container is not a press target")
        check(!AssistantClickPolicy.canPress(role:"AXTextField",advertised:[],enabled:true),"Text field retains separate focus behavior")
        check(AssistantClickPolicy.canPress(role:"AXLink",advertised:["AXPress"],enabled:nil),"Advertised semantic press remains supported")
        func maps(_ raw:String,_ app:String = "com.apple.Maps") -> Bool {
            guard let url = URL(string:raw) else { return false }
            return AssistantMapLinkPolicy.usesCurrentMaps(url:url,bundleID:app)
        }
        check(maps("https://maps.apple.com/?daddr=Siesta%20Key"),"Directions stay in current Maps")
        check(maps("https://maps.apple.com/?q=Siesta%20Key"),"Search stays in current Maps")
        check(maps("https://maps.apple.com/?saddr=Miami&daddr=Siesta%20Key&dirflg=d"),"Explicit starting point and travel mode remain valid")
        check(!maps("https://maps.apple.com/?daddr=Siesta%20Key","com.google.Chrome"),"Current browser is not redirected to Maps")
        for raw in ["https://maps.apple.com.example.com/?q=place", "https://example.com/?q=place", "https://maps.apple.com@evil.example/?q=place", "https://user@maps.apple.com/?q=place", "https://maps.apple.com:1234/?q=place", "file://maps.apple.com/?q=place", "maps://maps.apple.com/?q=place", "https://maps.apple.com/other?q=place", "https://maps.apple.com/?q=", "https://maps.apple.com/?q=place#fragment"] {
            check(!maps(raw),"Unsupported link must not be routed to Maps: " + raw)
        }
        check(AssistantMapLinkPolicy.refusesFallback(url:URL(string:"https://maps.apple.com/?q=place#fragment")!,bundleID:"com.apple.Maps"),"Unsupported Maps link must not escape to Safari")
        check(!AssistantMapLinkPolicy.refusesFallback(url:URL(string:"https://example.com/")!,bundleID:"com.apple.Maps"),"Explicit unrelated web navigation can use its browser")
        let window = AssistantWindowSettlePolicy.Window(id:7,frame:CGRect(x:0,y:20,width:800,height:600))
        let moved = AssistantWindowSettlePolicy.Window(id:7,frame:CGRect(x:0,y:20,width:850,height:600))
        var delayed = AssistantWindowSettlePolicy(originalPID:10,expectedPID:20,deadline:5)
        check(delayed.observe(now:0,foregroundPID:10,window:nil,activityUnchanged:true) == .waiting,"Original app may remain during launch")
        check(delayed.observe(now:1,foregroundPID:20,window:nil,activityUnchanged:true) == .waiting,"Launched app may not yet have a window")
        check(delayed.observe(now:1.5,foregroundPID:20,window:window,activityUnchanged:true) == .waiting,"A late window is allowed")
        check(delayed.observe(now:1.75,foregroundPID:20,window:window,activityUnchanged:true) == .waiting,"250 ms alone is not stable")
        check(delayed.observe(now:1.9,foregroundPID:20,window:window,activityUnchanged:true) == .ready,"Stable target after delayed launch succeeds")
        check(delayed.observe(now:2,foregroundPID:20,window:moved,activityUnchanged:true) == .waiting,"Window animation resets settle interval")
        check(delayed.observe(now:2.4,foregroundPID:20,window:moved,activityUnchanged:true) == .ready,"Resized window must stabilize anew")
        check(delayed.observe(now:2.5,foregroundPID:10,window:nil,activityUnchanged:true) == .changed,"Returning to original app after arrival stops")
        var takeover = AssistantWindowSettlePolicy(originalPID:10,expectedPID:20,deadline:5)
        check(takeover.observe(now:0.1,foregroundPID:30,window:nil,activityUnchanged:true) == .changed,"Unrelated app is never adopted")
        check(takeover.observe(now:0.1,foregroundPID:20,window:window,activityUnchanged:false) == .changed,"User input or cancellation stops before adoption")
        var timeout = AssistantWindowSettlePolicy(originalPID:10,expectedPID:20,deadline:5)
        check(timeout.observe(now:5,foregroundPID:10,window:nil,activityUnchanged:true) == .timedOut,"Missing window is bounded")
        var invalid = AssistantWindowSettlePolicy(originalPID:10,expectedPID:20,deadline:5)
        check(invalid.observe(now:1,foregroundPID:20,window:.init(id:7,frame:.zero),activityUnchanged:true) == .waiting,"Zero-size window is not ready")
        print("Assistant window policy: \(count) checks passed")
    }
}
