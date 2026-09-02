import Foundation

/// Destinations the Attention tab can push that are not a workspace or a pane.
/// Kept out of `WorkspaceRoute` so the Workspaces tab's path — which
/// `HerdrAppModel.repairNavigation` prunes against live workspace and pane ids
/// — stays a pure workspace/pane list.
enum AttentionRoute: Hashable, Sendable {
    case activity
}
