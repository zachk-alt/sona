import Foundation

@main struct AssistantDeadlineTests {
    static func main() async {
        let fast = try? await AssistantCaptureDeadline<Int>().wait(seconds:0.2) { completion in completion(.success(42)) }
        precondition(fast == 42)
        let began = ProcessInfo.processInfo.systemUptime
        let slow = try? await AssistantCaptureDeadline<Int>().wait(seconds:0.04) { completion in
            DispatchQueue.global().asyncAfter(deadline:.now()+0.15) { completion(.success(7)) }
        }
        precondition(slow == nil && ProcessInfo.processInfo.systemUptime-began < 0.12)
        let task = Task {
            try? await AssistantCaptureDeadline<Int>().wait(seconds:5) { completion in
                DispatchQueue.global().asyncAfter(deadline:.now()+0.15) { completion(.success(7)) }
            }
        }
        try? await Task.sleep(for:.milliseconds(10)); task.cancel()
        let cancelled = await task.value
        precondition(cancelled == nil)
        try? await Task.sleep(for:.milliseconds(180))
        var conversation = AssistantConversation()
        for i in 0..<40 { conversation.append(role:i.isMultiple(of:2) ? "user" : "assistant",content:String(repeating:"x",count:2500)) }
        precondition(conversation.messages.count <= 16 && conversation.messages.reduce(0,{$0+$1.content.utf8.count}) <= 32*1024)
        conversation.append(role:"user",content:String(repeating:"👩‍💻",count:1600))
        precondition(conversation.messages.last!.content.utf8.count <= 16*1024)
        conversation.clear(); precondition(conversation.messages.isEmpty)
        print("PASS: capture callback success, deadline, cancellation discarded late callbacks, and bounded/cleared conversation memory")
    }
}
