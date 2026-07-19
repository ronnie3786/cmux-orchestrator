import Foundation

struct OpenCodeTerminalInteraction: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case permission
        case question
        case questionReview
    }

    struct ReviewItem: Equatable, Identifiable, Sendable {
        var label: String
        var value: String

        var id: String { "\(label):\(value)" }
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
    var reviewItems: [ReviewItem] = []
    var allowsMultipleSelection = false

    var promptID: String {
        let optionID = options.joined(separator: "|")
        let reviewID = reviewItems.map(\.id).joined(separator: "|")
        return "\(kind)|\(detail)|\(optionID)|\(reviewID)|multi:\(allowsMultipleSelection)"
    }
}
