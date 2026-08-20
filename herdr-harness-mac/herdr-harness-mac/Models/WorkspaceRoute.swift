import Foundation

enum WorkspaceRoute: Hashable, Sendable {
    case workspace(String)
    case pane(String)
}
