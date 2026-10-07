import Foundation
import CoreGraphics

@main enum AssistantCapturePolicyTests {
    static func main() {
        var count = 0
        func check(_ value:Bool,_ description:String) { precondition(value,description); count += 1 }
        typealias Window = AssistantCapturePolicy.Window
        let main = Window(id:100,frame:CGRect(x:0,y:88,width:1440,height:812))
        let strips = [30,41,47,124].enumerated().map { index,height in
            Window(id:UInt32(index+1),frame:CGRect(x:0,y:0,width:1440,height:height))
        }
        check(AssistantCapturePolicy.window(strips+[main],focusedFrame:nil) == main,"Chrome content wins over four auxiliary strips")
        check(AssistantCapturePolicy.window(strips+[main],focusedFrame:main.frame) == main,"Focused window geometry selects Chrome content")
        check(AssistantCapturePolicy.window(strips,focusedFrame:nil) == nil,"Unproven auxiliary-only inventory is unavailable")
        check(AssistantCapturePolicy.window(strips,focusedFrame:strips[3].frame) == strips[3],"AX proves which shallow window is actually focused")
        let dialog = Window(id:101,frame:CGRect(x:420,y:220,width:600,height:340))
        check(AssistantCapturePolicy.window(strips+[dialog,main],focusedFrame:main.frame) == dialog,"Front dialog wins even if AX still names parent")
        check(AssistantCapturePolicy.window([dialog,main],focusedFrame:dialog.frame) == dialog,"Focused dialog is never replaced by largest window")
        let smallDialog = Window(id:102,frame:CGRect(x:200,y:200,width:400,height:120))
        check(AssistantCapturePolicy.window([smallDialog,main],focusedFrame:nil) == smallDialog,"Small ordinary dialog remains capturable")
        let shallow = Window(id:103,frame:CGRect(x:200,y:200,width:800,height:120))
        check(AssistantCapturePolicy.window([shallow,main],focusedFrame:nil) == shallow,"Wide short dialog does not match Chrome body's width or location")
        check(AssistantCapturePolicy.window([shallow,main],focusedFrame:main.frame) == shallow,"Stale parent AX cannot skip wide short foreground dialog")
        check(AssistantCapturePolicy.window([shallow,main],focusedFrame:shallow.frame) == shallow,"AX can prove a genuinely shallow focused window")
        let fullWidthDialog = Window(id:106,frame:CGRect(x:0,y:320,width:1440,height:140))
        check(AssistantCapturePolicy.window([fullWidthDialog,main],focusedFrame:nil) == fullWidthDialog,"Full-width modal in content area is not a top toolbar")
        let topDialog = Window(id:107,frame:CGRect(x:0,y:88,width:1440,height:140))
        check(AssistantCapturePolicy.window([topDialog,main],focusedFrame:nil) == topDialog,"Top dialog is not above the content body's top edge")
        check(AssistantCapturePolicy.window([topDialog,main],focusedFrame:main.frame) == topDialog,"Stale AX parent must not hide a top dialog")
        check(AssistantCapturePolicy.window([topDialog,main],focusedFrame:topDialog.frame) == topDialog,"Exact AX match remains authoritative for a shallow top dialog")
        let another = Window(id:104,frame:CGRect(x:20,y:40,width:1000,height:600))
        check(AssistantCapturePolicy.window([another,main],focusedFrame:nil) == another,"Keep front order, never largest area")
        check(AssistantCapturePolicy.window([another,main],focusedFrame:main.frame) == another,"Do not skip another substantive front window")
        let moved = Window(id:105,frame:main.frame.offsetBy(dx:8,dy:4))
        check(AssistantCapturePolicy.window(strips+[moved],focusedFrame:main.frame) == strips[0],"Unmatched strip geometry never jumps to a background body")
        check(AssistantCapturePolicy.window([],focusedFrame:main.frame) == nil,"No foreign or off-screen window is invented from AX")
        // Exact observed Chrome link-status geometry: a 302x22 logical window
        // becomes the erroneous 604x44 Retina capture if it wins selection.
        let bubble=Window(id:6721,frame:CGRect(x:-1,y:879,width:302,height:22))
        let inventory=[main.frame]
        check(AssistantCapturePolicy.needsWindowMetadata([bubble]+strips+[main],focusedFrame:main.frame),"Only suspicious status shape requests bounded AX inventory")
        check(!AssistantCapturePolicy.needsWindowMetadata([dialog,main],focusedFrame:main.frame),"Ordinary dialog adds no AX inventory work")
        check(AssistantCapturePolicy.window([bubble]+strips+[main],focusedFrame:main.frame,accessibilityWindows:inventory) == main,"Observed lower-left Chrome status bubble cannot replace focused content")
        check(AssistantCapturePolicy.window([bubble,main],focusedFrame:main.frame) == nil,"Unproven inventory cannot authorize skipping a tiny foreground window")
        check(AssistantCapturePolicy.window([bubble,main],focusedFrame:nil,accessibilityWindows:inventory) == nil,"Missing AX focus leaves status shape ambiguous")
        check(AssistantCapturePolicy.window([bubble,main],focusedFrame:main.frame,accessibilityWindows:[]) == nil,"Off-Space empty AX inventory is not proof")
        check(AssistantCapturePolicy.window([bubble,main],focusedFrame:bubble.frame) == bubble,"Actually focused tiny window retains identity")
        check(AssistantCapturePolicy.window([bubble,main],focusedFrame:main.frame,accessibilityWindows:[main.frame,bubble.frame]) == bubble,"AX-listed tiny dialog or focused top-level popup is never skipped")
        check(AssistantCapturePolicy.window([bubble,main],focusedFrame:main.frame,accessibilityWindows:[dialog.frame]) == nil,"Inventory must independently include the focused AX window")
        check(AssistantCapturePolicy.window([bubble,dialog,main],focusedFrame:main.frame,accessibilityWindows:[main.frame,dialog.frame]) == dialog,"A front dialog still wins after a proven status bubble is excluded")
        let rightBubble=Window(id:6722,frame:CGRect(x:1139,y:879,width:302,height:22))
        check(AssistantCapturePolicy.window([rightBubble,main],focusedFrame:main.frame,accessibilityWindows:inventory) == main,"Right-corner status bubble has symmetric bounded handling")
        check(AssistantCapturePolicy.window([bubble,rightBubble,main],focusedFrame:main.frame,accessibilityWindows:inventory) == main,"Two proven lower-corner auxiliary windows are skipped without recursion")
        let interior=Window(id:6723,frame:CGRect(x:200,y:879,width:302,height:22))
        check(AssistantCapturePolicy.window([interior,main],focusedFrame:main.frame,accessibilityWindows:inventory) == interior,"Unrelated bottom popup is not classified by small size alone")
        let upper=Window(id:6724,frame:CGRect(x:-1,y:100,width:302,height:22))
        check(AssistantCapturePolicy.window([upper,main],focusedFrame:main.frame,accessibilityWindows:inventory) == upper,"Upper popup is not a lower-edge status bubble")
        let tall=Window(id:6725,frame:CGRect(x:0,y:780,width:400,height:120))
        check(AssistantCapturePolicy.window([tall,main],focusedFrame:main.frame,accessibilityWindows:inventory) == tall,"Small normal dialog at lower corner remains foreground")
        let outer=CGRect(x:0,y:0,width:1440,height:900)
        check(AssistantCapturePolicy.window([bubble]+strips+[main],focusedFrame:outer,accessibilityWindows:[outer]) == main,"Full-screen outer AX window maps only through real adjoining header-band evidence")
        check(AssistantCapturePolicy.window([bubble,main],focusedFrame:outer,accessibilityWindows:[outer]) == nil,"Outer containment without toolbar proof does not invent a document match")
        check(AssistantCapturePolicy.window([bubble]+Array(strips.prefix(3))+[main],focusedFrame:outer,accessibilityWindows:[outer]) == nil,"Toolbar evidence must cover the full outer-to-content header difference")
        let duplicate=Window(id:6726,frame:main.frame)
        check(AssistantCapturePolicy.window([bubble,main,duplicate],focusedFrame:main.frame,accessibilityWindows:inventory) == nil,"Ambiguous same-geometry CG IDs do not become an exact focused-body guess")
        check(AssistantCapturePolicy.window([bubble]+strips+[main,duplicate],focusedFrame:outer,accessibilityWindows:[outer]) == nil,"Ambiguous full-screen body IDs are not guessed")
        check(AssistantCapturePolicy.window([bubble]+strips+[main],focusedFrame:outer.offsetBy(dx:10,dy:0),accessibilityWindows:[outer.offsetBy(dx:10,dy:0)]) == nil,"Shifted outer AX parent is not associated with a stale content body")
        check(AssistantCapturePolicy.matchesFrame(main.frame,main.frame),"Identical CG and SCK geometry matches")
        check(AssistantCapturePolicy.matchesFrame(main.frame,main.frame.offsetBy(dx:1,dy:1)),"Subpixel geometry rounding stays within bounded two-point tolerance")
        check(!AssistantCapturePolicy.matchesFrame(main.frame,bubble.frame),"Tiny SCK geometry cannot capture in place of retained document geometry")
        check(!AssistantCapturePolicy.matchesFrame(main.frame,main.frame.offsetBy(dx:3,dy:0)),"A changed SCK origin is rejected")
        check(!AssistantCapturePolicy.matchesFrame(main.frame,CGRect(x:0,y:88,width:1440,height:809)),"A changed SCK extent is rejected")
        check(AssistantCapturePolicy.completeWindowFrames(inventory,focusedTopLevel:main.frame) != nil,"Complete AX window plus focused top-level metadata permits classification")
        check(AssistantCapturePolicy.completeWindowFrames(inventory,focusedTopLevel:nil) == nil,"Missing or failed focused-element/top-level read does not certify parent-only inventory")
        check(AssistantCapturePolicy.completeWindowFrames(nil,focusedTopLevel:main.frame) == nil,"Missing AX window list does not certify inventory")
        check(AssistantCapturePolicy.completeWindowFrames([],focusedTopLevel:main.frame) == nil,"Empty off-Space window inventory is not complete")
        check(AssistantCapturePolicy.completeWindowFrames(inventory,focusedTopLevel:.zero) == nil,"Unusable top-level geometry refuses classification")
        check(AssistantCapturePolicy.captureFrameMatches(main.frame,main.frame),"Exact retained CG and captured SCK geometry agrees")
        check(!AssistantCapturePolicy.captureFrameMatches(main.frame,main.frame.offsetBy(dx:1,dy:0)),"Capture coordinates do not borrow fuzzy AX matching tolerance")
        check(!AssistantCapturePolicy.captureFrameMatches(main.frame,CGRect(x:0,y:88,width:1441,height:812)),"One-point capture size difference is rejected to preserve normalized click mapping")
        check(!AssistantCapturePolicy.usable(CGRect(x:0,y:0,width:1,height:400)),"Degenerate window rejected")
        check(!AssistantCapturePolicy.usable(CGRect(x:0,y:0,width:Double.infinity,height:400)),"Nonfinite geometry rejected")

        func pixels(_ width:Double,_ height:Double,_ scale:Double) -> AssistantCapturePolicy.Pixels? {
            AssistantCapturePolicy.pixels(points:CGSize(width:width,height:height),pixelsPerPoint:scale)
        }
        check(pixels(1440,900,2) == .init(width:2560,height:1600),"Retina 1440x900 retains 1.78x detail")
        check(pixels(1440,812,2) == .init(width:2560,height:1444),"Chrome content keeps full-window aspect within one pixel")
        check(pixels(1440,900,1) == .init(width:1440,height:900),"Non-Retina content is not artificially enlarged")
        check(pixels(600,340,2) == .init(width:1200,height:680),"Retina dialog retains native 2x pixels")
        check(pixels(900,1440,2) == .init(width:1600,height:2560),"Portrait uses same uniform scale")
        check(pixels(5000,5000,2) == .init(width:2560,height:2560),"Square capture has bounded allocation")
        for invalid in [0.0,-1.0,Double.infinity,Double.nan] {
            check(pixels(1440,900,invalid) == nil,"Invalid scale safely rejected")
        }
        for width in [320.5,600,1440,1920,5120] {
            for height in [200.25,900,1440,3000] {
                let result = pixels(width,height,2)!
                let scale = min(2,Double(AssistantCapturePolicy.maximumEdge)/max(width,height))
                check(abs(Double(result.width)-width*scale) <= 0.5 && abs(Double(result.height)-height*scale) <= 0.5,"Uniform scale rounded within half a pixel")
                check(result.width*result.height <= AssistantCapturePolicy.maximumPixels,"Pixel allocation remains bounded")
            }
        }
        check(AssistantCapturePolicy.maximumBytes == 2*1024*1024,"Original encoded limit retained")
        check(AssistantCapturePolicy.jpegQualities.count == 4 && AssistantCapturePolicy.jpegQualities.allSatisfy { (0.5...0.9).contains($0) },"Finite conservative encoding ladder")
        print("Assistant capture policy: \(count) checks passed; no screen capture or GUI.")
    }
}
