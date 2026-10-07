import Foundation

@main enum AssistantClickDiagnosticsTests {
    static func main() {
        var count=0
        func check(_ value:Bool,_ label:String) { precondition(value,label); count += 1 }
        typealias D=AssistantClickDiagnostics
        let hit=D.line(reason:.hitTestFailed,phase:.initial,depth:0,role:nil,axResult:-25202)
        check(hit == "assistant: native_click_failure action=click phase=initial reason=hit_test_failed depth=0 role=unavailable ax=-25202","Fixed initial hit failure includes numeric AX result")
        check(D.line(reason:.disabledControl,phase:.recheck,depth:2,role:"AXButton").contains("phase=recheck reason=disabled_control depth=2 role=AXButton ax=none"),"Disabled recheck is distinct from missing semantic action")
        check(D.line(reason:.parentDepthExhausted,phase:.initial,depth:4,role:"AXGroup").contains("reason=parent_depth_exhausted depth=4"),"Ancestor-depth limit has a distinct fixed reason")
        check(D.line(reason:.noSemanticTarget,phase:.initial,depth:1,role:"AXWebArea").contains("reason=no_semantic_target"),"Root without actionable ancestor has its own reason")
        check(D.line(reason:.pressFailed,phase:.apply,depth:3,role:"AXLink",axResult:-25205).hasSuffix("role=AXLink ax=-25205"),"Failed AXPress records role and numeric error")
        check(D.line(reason:.focusFailed,phase:.apply,depth:0,role:"AXTextField",axResult:-25204).contains("reason=ax_focus_failed"),"Failed focus has its own reason")
        for untrusted in ["example page title","AXButton\nrequest=secret","AXLink value=private","",String(repeating:"x",count:10000)] {
            let line=D.line(reason:.noSemanticTarget,phase:.initial,depth:0,role:untrusted)
            check(line.hasSuffix("role=other ax=none") && !line.contains("\n") && line.count < 180,"Unknown role content is never emitted")
        }
        check(D.line(reason:.noSemanticTarget,phase:.initial,depth:Int.min,role:"AXUnknown").contains("depth=0"),"Negative diagnostic depth is bounded")
        check(D.line(reason:.noSemanticTarget,phase:.initial,depth:Int.max,role:"AXUnknown").contains("depth=12"),"Excessive diagnostic depth is bounded")
        print("Assistant click diagnostics: \(count) checks passed; fixed categories only, no GUI or provider.")
    }
}
