import Foundation

struct PiUserMessage: Identifiable, Equatable, Sendable {
    let id: String
    var text: String
    var timestamp: Date?
}
