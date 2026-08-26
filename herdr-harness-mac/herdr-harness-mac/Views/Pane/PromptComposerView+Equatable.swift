import SwiftUI

extension PromptComposerView: Equatable {
    static func == (lhs: PromptComposerView, rhs: PromptComposerView) -> Bool {
        lhs.model === rhs.model
            && lhs.pane.isEqualIgnoringRevision(to: rhs.pane)
            && lhs.workspace.isEqualIgnoringPaneRevisions(to: rhs.workspace)
            && lhs.draft == rhs.draft
            && lhs.attachments == rhs.attachments
            && lhs.focusRequest == rhs.focusRequest
            && lhs.dismissFocusRequest == rhs.dismissFocusRequest
            && lhs.piConfiguration == rhs.piConfiguration
            && lhs.responseAudioPlayer === rhs.responseAudioPlayer
            && lhs.toolRowFit == rhs.toolRowFit
    }
}
