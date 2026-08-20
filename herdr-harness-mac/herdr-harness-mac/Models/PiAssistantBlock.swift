import Foundation

struct PiAssistantBlock: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case streaming
        case complete
        case failed(String?)
    }

    let id: String
    var text: String
    var status: Status
    var timestamp: Date?
}
