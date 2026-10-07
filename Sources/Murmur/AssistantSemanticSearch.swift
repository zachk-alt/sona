import Foundation

/// Shared bounded ancestor traversal. It performs no accessibility reads or
/// actions itself; native inspection supplies a parent, candidate or refusal.
enum AssistantSemanticSearch {
    static let maximumNodes=12
    static let duration:TimeInterval=0.75
    static let maximumRead:TimeInterval=0.1
    enum Failure:Error { case deadline, cycle, depth, boundary, foreignProcess, secure, disabled, noTarget, metadata }
    enum Step<Node,Match> { case candidate(Match), parent(Node), blocked(Failure) }
    struct Budget {
        let deadline:TimeInterval
        private let clock:() -> TimeInterval
        init(clock:@escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
            self.clock=clock; deadline=clock()+AssistantSemanticSearch.duration
        }
        func readTimeout() throws -> TimeInterval {
            let remaining=deadline-clock()
            guard remaining.isFinite, remaining > 0 else { throw Failure.deadline }
            return min(AssistantSemanticSearch.maximumRead,remaining)
        }
        func check() throws { _ = try readTimeout() }
    }
    static func find<Node,Match>(start:Node,budget:Budget,equal:(Node,Node) -> Bool,
        inspect:(Node,Int,Budget) throws -> Step<Node,Match>) throws -> Match {
        var item=start, visited:[Node]=[]
        for depth in 0..<maximumNodes {
            try budget.check()
            guard !visited.contains(where:{ equal($0,item) }) else { throw Failure.cycle }
            visited.append(item)
            let step=try inspect(item,depth,budget)
            // A late metadata reply must never become a usable action target.
            try budget.check()
            switch step {
            case .candidate(let match): return match
            case .parent(let parent): item=parent
            case .blocked(let failure): throw failure
            }
        }
        throw Failure.depth
    }
}
