import Foundation

struct OpenCodeTerminalInteraction: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case permission
        case question
    }

    enum NavigationAxis: Equatable, Sendable {
        case horizontal
        case vertical
    }

    var kind: Kind
    var title: String
    var detail: String
    var options: [String]
    var navigationAxis: NavigationAxis
}
