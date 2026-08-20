import SwiftUI

/// Hosts the attention deck inside the Mac window's detail column.
///
/// iOS wrapped the deck in its own `NavigationStack` and *pushed* the tapped
/// pane. The Mac has one persistent split view, so opening a pane is purely a
/// selection change — the root shell swaps the detail to that pane's session on
/// its own. Marking the originating alert read stays fire-and-forget, exactly as
/// on iOS.
struct AttentionNavigationView: View {
    @Bindable var model: HerdrAppModel

    var body: some View {
        AttentionView(model: model) { pane, alert in
            model.selectedWorkspaceID = pane.workspaceID
            model.selectedPaneID = pane.id
            if let alert {
                Task { await model.markAlertRead(alert) }
            }
        }
    }
}
