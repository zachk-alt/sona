import Foundation
import ApplicationServices

@main enum AssistantSemanticSearchTests {
    final class Clock { var now:TimeInterval=0 }
    struct Node { var parent:Int?; var actionable=false; var window=1; var secure=false; var disabled=false }
    static func main() throws {
        typealias Search=AssistantSemanticSearch
        var checks=0
        func check(_ value:Bool,_ label:String) { precondition(value,label); checks += 1 }
        func fixture(_ count:Int,_ actionable:Int) -> [Node] {
            (0..<count).map { Node(parent:$0+1<count ? $0+1 : nil,actionable:$0 == actionable) }
        }
        func find(_ nodes:[Node],clock:Clock=Clock(),elapsedPerRead:Double=0,visited:inout [Int]) throws -> Int {
            let budget=Search.Budget(clock:{ clock.now })
            return try Search.find(start:0,budget:budget,equal:==) { index,_,_ in
                visited.append(index); clock.now += elapsedPerRead
                let node=nodes[index]
                if node.window != 1 { return .blocked(.boundary) }
                if node.secure { return .blocked(.secure) }
                if node.disabled { return .blocked(.disabled) }
                if node.actionable { return .candidate(index) }
                if let parent=node.parent { return .parent(parent) }
                return .blocked(.noTarget)
            }
        }
        var visited:[Int]=[]
        let nested=try find(fixture(8,6),visited:&visited)
        check(nested == 6 && visited == Array(0...6),"Actionable nested web ancestor beyond former four-node limit is found")
        visited=[]; let last=try find(fixture(13,11),visited:&visited)
        check(last == 11 && visited.count == 12,"Twelfth node can be the verified semantic target")
        visited=[]
        do { _ = try find(fixture(13,12),visited:&visited); preconditionFailure("Unbounded ancestor search") }
        catch Search.Failure.depth { check(visited.count == 12,"Thirteenth node is never inspected") }
        var cycle=fixture(5,4); cycle[2].parent=0; visited=[]
        do { _ = try find(cycle,visited:&visited); preconditionFailure("Cycle accepted") }
        catch Search.Failure.cycle { check(visited == [0,1,2],"Repeated identity stops before repeated metadata reads") }
        var boundary=fixture(8,6); boundary[2].window=2; visited=[]
        do { _ = try find(boundary,visited:&visited); preconditionFailure("Different AX window accepted") }
        catch Search.Failure.boundary { check(visited == [0,1,2],"Search never climbs through another window to an actionable ancestor") }
        var disabled=fixture(8,6); disabled[2].disabled=true; visited=[]
        do { _ = try find(disabled,visited:&visited); preconditionFailure("Disabled ancestor bypassed") }
        catch Search.Failure.disabled { check(visited == [0,1,2],"Disabled control remains a hard stop") }
        var secure=fixture(8,6); secure[2].secure=true; visited=[]
        do { _ = try find(secure,visited:&visited); preconditionFailure("Secure control bypassed") }
        catch Search.Failure.secure { check(visited == [0,1,2],"Secure control remains a hard stop") }
        visited=[]
        do { _ = try find(fixture(8,5),elapsedPerRead:0.13,visited:&visited); preconditionFailure("Late actionable reply accepted") }
        catch Search.Failure.deadline { check(visited.count == 6,"A candidate delivered after the total deadline is rejected") }
        visited=[]
        do { _ = try find(fixture(2,9),visited:&visited); preconditionFailure("Absent target accepted") }
        catch Search.Failure.noTarget { check(visited == [0,1],"Missing parent stops at the actual root") }
        let clock=Clock(), budget=Search.Budget(clock:{ clock.now })
        check(try budget.readTimeout() == 0.1,"Every read retains the existing hundred-millisecond ceiling")
        clock.now=0.745
        check(abs((try budget.readTimeout())-0.005) < 0.000001,"Read timeout shrinks to remaining total budget")
        clock.now=0.75
        do { _ = try budget.readTimeout(); preconditionFailure("Expired read allowed") }
        catch Search.Failure.deadline { check(true,"No read starts at the deadline") }
        clock.now=Double.nan
        do { _ = try budget.readTimeout(); preconditionFailure("Nonfinite clock accepted") }
        catch Search.Failure.deadline { check(true,"Invalid monotonic timing fails safely") }
        check(AssistantAXReadPolicy.disposition(.success) == .value,"Successful AX metadata is usable")
        for result:AXError in [.attributeUnsupported,.noValue] {
            check(AssistantAXReadPolicy.disposition(result) == .absent,"Only legitimate absent optional metadata is optional")
        }
        for result:AXError in [.cannotComplete,.invalidUIElement,.apiDisabled,.failure,.illegalArgument,.notImplemented] {
            check(AssistantAXReadPolicy.disposition(result) == .failed,"Failed AX safety reads are never downgraded to missing metadata")
        }
        print("Assistant semantic search: \(checks) checks passed; nested ancestors, cycles, boundaries and real shared deadline policy; no GUI or provider.")
    }
}
