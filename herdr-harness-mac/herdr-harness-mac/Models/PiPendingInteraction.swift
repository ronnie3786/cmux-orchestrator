import Foundation

struct PiPendingInteraction: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case select
        case confirm
        case input
        case editor
        case unknown
    }

    let id: String
    var kind: Kind
    var title: String
    var message: String?
    var options: [String]
    var placeholder: String?
}
