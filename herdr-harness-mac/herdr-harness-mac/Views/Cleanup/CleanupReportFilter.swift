import Foundation

enum CleanupReportFilter: String, CaseIterable, Identifiable {
    case all
    case ready
    case attention
    case keep

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .ready: "Ready"
        case .attention: "Needs you"
        case .keep: "Keep open"
        }
    }

    func includes(_ pane: CleanupPaneReport) -> Bool {
        switch self {
        case .all:
            true
        case .ready:
            pane.safeToClose
        case .attention:
            pane.classification == .blocked || pane.classification == .needsHuman
        case .keep:
            !pane.safeToClose && pane.classification != .blocked && pane.classification != .needsHuman
        }
    }
}
