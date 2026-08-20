import Foundation

enum WorkspaceFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case attention = "Needs you"
    case active = "Active"

    var id: Self { self }
}
