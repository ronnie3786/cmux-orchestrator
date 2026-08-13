import Foundation

enum PiMarkdownBlock: Identifiable, Equatable, Sendable {
    case paragraph(id: Int, text: String)
    case code(id: Int, language: String?, code: String)
    case bullet(id: Int, text: String)
    case numbered(id: Int, number: String, text: String)
    case quote(id: Int, text: String)

    var id: Int {
        switch self {
        case let .paragraph(id, _), let .code(id, _, _), let .bullet(id, _),
             let .numbered(id, _, _), let .quote(id, _): id
        }
    }
}
