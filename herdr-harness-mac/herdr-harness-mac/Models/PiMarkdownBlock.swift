import Foundation

enum PiMarkdownBlock: Identifiable, Equatable, Sendable {
    case paragraph(id: Int, text: String)
    case heading(id: Int, level: Int, text: String)
    case code(id: Int, language: String?, code: String)
    case list(id: Int, items: [PiMarkdownListItem])
    case quote(id: Int, text: String)
    case table(id: Int, table: PiMarkdownTable)
    case thematicBreak(id: Int)

    var id: Int {
        switch self {
        case let .paragraph(id, _), let .heading(id, _, _), let .code(id, _, _),
             let .list(id, _), let .quote(id, _), let .table(id, _),
             let .thematicBreak(id):
            id
        }
    }
}

struct PiMarkdownListItem: Equatable, Sendable {
    enum Marker: Equatable, Sendable {
        case bullet
        case number(String)
        case task(isCompleted: Bool)
    }

    let marker: Marker
    let text: String
    let depth: Int
}

struct PiMarkdownTable: Equatable, Sendable {
    enum ColumnAlignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    let headers: [String]
    let alignments: [ColumnAlignment]
    let rows: [[String]]
}
