import Foundation

enum PaneResultArtifacts {
    static func matching(_ artifacts: [AgentResultArtifact], pane: HerdrPane) -> [AgentResultArtifact] {
        artifacts.filter {
            $0.originType == .pane && $0.machineID == pane.machineID && $0.originID == pane.paneID
        }.sorted {
            let lhs = $0.createdDate ?? .distantPast
            let rhs = $1.createdDate ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }
}
