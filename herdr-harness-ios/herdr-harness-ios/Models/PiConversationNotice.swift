import Foundation

struct PiConversationNotice: Identifiable, Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case neutral
        case warning
        case error
    }

    let id: String
    var title: String
    var detail: String?
    var tone: Tone
    var timestamp: Date?
}
