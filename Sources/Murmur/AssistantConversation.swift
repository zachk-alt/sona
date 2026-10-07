import Foundation

struct AssistantMessage: Codable, Equatable {
    let role:String
    let content:String
}
/// Only the current panel conversation. No images, documents, disk history or
/// automatic memory acquisition. Evict complete oldest entries at fixed bounds.
struct AssistantConversation {
    private(set) var messages:[AssistantMessage] = []
    mutating func append(role:String,content:String) {
        guard ["user","assistant"].contains(role), !content.isEmpty else { return }
        var text = content
        while text.utf8.count > 16*1024 { text.removeLast() }
        messages.append(.init(role:role,content:text))
        while messages.count > 16 || messages.reduce(0,{$0+$1.content.utf8.count}) > 32*1024 { messages.removeFirst() }
    }
    mutating func clear() { messages.removeAll(keepingCapacity:false) }
}
