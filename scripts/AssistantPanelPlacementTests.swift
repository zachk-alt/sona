import Foundation
import CoreGraphics

@main enum AssistantPanelPlacementTests {
    typealias Policy=AssistantPanelPlacement
    static func main() {
        var checks=0
        func check(_ value:Bool,_ label:String) { precondition(value,label); checks += 1 }
        func point(_ actual:CGPoint?,_ x:CGFloat,_ y:CGFloat,_ label:String) {
            check(actual.map { abs($0.x-x)<0.00001 && abs($0.y-y)<0.00001 } ?? false,label)
        }
        let main=Policy.Display(quartzFrame:CGRect(x:0,y:0,width:1440,height:900),frame:CGRect(x:0,y:0,width:1440,height:900),visibleFrame:CGRect(x:0,y:0,width:1440,height:875))
        let right=Policy.Display(quartzFrame:CGRect(x:1440,y:0,width:1920,height:1080),frame:CGRect(x:1440,y:-180,width:1920,height:1080),visibleFrame:CGRect(x:1440,y:-180,width:1920,height:1055))
        let above=Policy.Display(quartzFrame:CGRect(x:0,y:-1200,width:1920,height:1200),frame:CGRect(x:0,y:900,width:1920,height:1200),visibleFrame:CGRect(x:0,y:900,width:1920,height:1175))
        let left=Policy.Display(quartzFrame:CGRect(x:-1280,y:100,width:1280,height:800),frame:CGRect(x:-1280,y:0,width:1280,height:800),visibleFrame:CGRect(x:-1280,y:0,width:1280,height:775))
        let below=Policy.Display(quartzFrame:CGRect(x:0,y:900,width:1440,height:900),frame:CGRect(x:0,y:-900,width:1440,height:900),visibleFrame:CGRect(x:0,y:-900,width:1440,height:875))
        let displays=[main,right,above,left,below], size=CGSize(width:352,height:156)
        let anchor=CGRect(x:1230,y:875,width:20,height:25)
        let target=CGRect(x:100,y:100,width:800,height:600)
        func origin(_ target:CGRect,_ anchor:CGRect?=anchor,_ size:CGSize=size,_ screens:[Policy.Display]=displays,_ margin:CGFloat=26) -> CGPoint? {
            Policy.origin(target:target,displays:screens,menuAnchor:anchor,panelSize:size,glowMargin:margin)
        }
        point(origin(target),1064,739,"Same display preserves the exact existing menu placement")
        point(origin(CGRect(x:1800,y:100,width:1000,height:700)),2984,739,"Mixed-height right screen uses its AppKit frame")
        point(origin(CGRect(x:200,y:-1000,width:1000,height:700)),1544,1939,"Above screen maps Quartz negative Y to AppKit positive Y")
        point(origin(CGRect(x:-1100,y:200,width:900,height:600)),-376,639,"Left screen retains right-edge menu inset")
        point(origin(CGRect(x:200,y:1000,width:900,height:600)),1064,-161,"Below screen uses negative AppKit origin")
        point(origin(CGRect(x:1300,y:100,width:400,height:600)),2984,739,"Straddling window chooses greatest positive overlap")
        point(origin(CGRect(x:1240,y:100,width:400,height:600)),1064,739,"Equal overlap deterministically keeps first display")
        point(origin(target,nil),1084,739,"Missing anchor uses 180-point center inset")
        point(origin(target,CGRect(x:9000,y:9000,width:20,height:20)),1084,739,"Unknown anchor display uses fallback inset")
        point(origin(target,CGRect(x:CGFloat.nan,y:0,width:20,height:20)),1084,739,"Invalid optional anchor is ignored")
        point(origin(target,anchor,CGSize(width:392,height:332)),1044,563,"Expanded answer retains glass top and menu center")
        point(origin(target,CGRect(x:0,y:875,width:20,height:25)),-18,739,"Glass clamps left with 8-point padding while glow may extend")
        point(origin(target,CGRect(x:1430,y:875,width:10,height:25)),1106,739,"Glass clamps right with 8-point padding")
        point(origin(target,CGRect(x:1230,y:80,width:20,height:25)),1064,-18,"Low anchor clamps glass above bottom padding")
        point(origin(target,CGRect(x:1230,y:890,width:20,height:10)),1064,739,"Anchor above usable top respects the menu gap")
        point(origin(CGRect(x:0.1,y:0.1,width:0.1,height:0.1)),1064,739,"Tiny positive target has a valid display intersection")
        point(origin(target,anchor,CGSize(width:300,height:104),displays,0),1090,765,"Zero glow margin preserves glass placement")
        check(origin(CGRect(x:8000,y:8000,width:100,height:100)) == nil,"Offscreen target has no placement")
        check(origin(CGRect(x:3360,y:100,width:10,height:10)) == nil,"Touching a display edge has no positive overlap")
        check(origin(.zero) == nil,"Empty target is rejected")
        check(origin(CGRect(x:0,y:0,width:-10,height:20)) == nil,"Negative target extent is rejected")
        check(origin(CGRect(x:CGFloat.infinity,y:0,width:10,height:20)) == nil,"Infinite target is rejected")
        check(origin(CGRect(x:0,y:CGFloat.nan,width:10,height:20)) == nil,"NaN target is rejected")
        check(origin(target,anchor,CGSize(width:52,height:156)) == nil,"No inset glass width is rejected")
        check(origin(target,anchor,CGSize(width:352,height:CGFloat.nan)) == nil,"Invalid panel size is rejected")
        check(origin(target,anchor,size,displays,-1) == nil,"Negative glow margin is rejected")
        check(origin(target,anchor,size,displays,CGFloat.infinity) == nil,"Infinite glow margin is rejected")
        check(origin(target,anchor,size,[]) == nil,"No displays has no placement")
        let exact=Policy.Display(quartzFrame:CGRect(x:0,y:0,width:316,height:118),frame:CGRect(x:0,y:0,width:316,height:118),visibleFrame:CGRect(x:0,y:0,width:316,height:118))
        point(origin(CGRect(x:1,y:1,width:10,height:10),nil,size,[exact]),-18,-18,"Exact-fit visible area retains all glass padding")
        let narrow=Policy.Display(quartzFrame:exact.quartzFrame,frame:exact.frame,visibleFrame:CGRect(x:0,y:0,width:315,height:118))
        check(origin(target,nil,size,[narrow]) == nil,"Unfittable glass width refuses an offscreen placement")
        let short=Policy.Display(quartzFrame:exact.quartzFrame,frame:exact.frame,visibleFrame:CGRect(x:0,y:0,width:316,height:117))
        check(origin(target,nil,size,[short]) == nil,"Unfittable glass height refuses an offscreen placement")
        let invalid=Policy.Display(quartzFrame:main.quartzFrame,frame:main.frame,visibleFrame:CGRect(x:-1,y:0,width:1440,height:875))
        check(origin(target,nil,size,[invalid]) == nil,"Invalid visible frame outside its display is rejected")
        let dock=Policy.Display(quartzFrame:main.quartzFrame,frame:main.frame,visibleFrame:CGRect(x:50,y:50,width:1390,height:825))
        point(origin(target,CGRect(x:0,y:875,width:20,height:25),size,[dock]),32,739,"Visible dock insets constrain glass, not glow")
        let rightAnchor=CGRect(x:3180,y:875,width:20,height:25)
        point(origin(target,rightAnchor),1094,739,"Transferred inset uses the actual source display width")
        func recording(_ anchor:CGRect?,_ fallback:CGRect?=main.frame,_ screens:[Policy.Display]=displays) -> CGPoint? {
            Policy.recordingOrigin(displays:screens,menuAnchor:anchor,fallbackFrame:fallback,panelSize:size)
        }
        point(recording(anchor),1064,739,"Dictation preserves its ordinary menu anchor")
        point(recording(nil),1084,739,"Dictation missing anchor falls back inside its active display")
        point(recording(CGRect(x:-5000,y:875,width:20,height:25)),1084,739,"Overflowed dictation anchor cannot pull the panel offscreen")
        point(recording(CGRect(x:1230,y:9000,width:20,height:25)),1084,739,"Stale disconnected display anchor uses the active display")
        point(recording(CGRect(x:CGFloat.nan,y:875,width:20,height:25)),1084,739,"Nonfinite dictation anchor safely falls back")
        point(recording(nil,right.frame),3004,739,"Missing dictation anchor uses the chosen right-hand display")
        point(recording(nil,above.frame),1564,1939,"Missing dictation anchor handles displays above the main screen")
        point(recording(anchor,right.frame),1064,739,"Valid menu anchor takes precedence over fallback screen")
        point(recording(CGRect(x:1435,y:875,width:20,height:25),main.frame,[main]),1106,739,"Partially overflowed menu anchor clamps the whole glass onscreen")
        point(recording(nil,CGRect(x:9000,y:9000,width:20,height:20)),1084,739,"Stale fallback screen chooses the first available display")
        check(recording(nil,nil,[]) == nil,"No displays never invents a dictation location")
        print("Assistant panel placement: \(checks) checks passed; pure geometry only, no AppKit or GUI.")
    }
}
