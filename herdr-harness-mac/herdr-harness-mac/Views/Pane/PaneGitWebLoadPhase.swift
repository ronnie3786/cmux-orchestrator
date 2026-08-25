import Foundation

enum PaneGitWebLoadPhase: Equatable {
    case loading
    case ready
    case failed(String)
}
