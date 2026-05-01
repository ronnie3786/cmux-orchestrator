import ComposableArchitecture
import Foundation

extension HarnessFeature {
    func reduceAttachments(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
            case let .attachmentFilesPicked(workspaceID, urls):
                guard let workspace = state.workspaces.first(where: { $0.id == workspaceID }) else { return .none }
                let attachments = urls.map { url in
                    TerminalAttachment(
                        id: self.uuid(),
                        filename: url.lastPathComponent.isEmpty ? "attachment" : url.lastPathComponent,
                        sourceURL: url,
                        status: .uploading,
                        uploaded: nil,
                        error: nil
                    )
                }
                guard !attachments.isEmpty else { return .none }
                state.terminalAttachments[workspaceID, default: []].append(contentsOf: attachments)
                return .merge(
                    attachments.map { attachment in
                        uploadAttachmentEffect(state: state, workspace: workspace, attachment: attachment)
                    }
                )

            case let .attachmentUploadSucceeded(workspaceID, attachmentID, response):
                guard let index = state.terminalAttachments[workspaceID]?.firstIndex(where: { $0.id == attachmentID }) else {
                    return .none
                }
                state.terminalAttachments[workspaceID]?[index].status = .uploaded
                state.terminalAttachments[workspaceID]?[index].uploaded = response.attachment
                state.terminalAttachments[workspaceID]?[index].error = nil
                state.errorMessage = nil
                return .none

            case let .attachmentUploadFailed(workspaceID, attachmentID, message):
                guard let index = state.terminalAttachments[workspaceID]?.firstIndex(where: { $0.id == attachmentID }) else {
                    return .none
                }
                state.terminalAttachments[workspaceID]?[index].status = .failed
                state.terminalAttachments[workspaceID]?[index].error = message
                return .none

            case let .removeAttachment(workspaceID, attachmentID):
                state.terminalAttachments[workspaceID]?.removeAll { $0.id == attachmentID }
                if state.terminalAttachments[workspaceID]?.isEmpty == true {
                    state.terminalAttachments[workspaceID] = nil
                }
                return .none

            case let .retryAttachment(workspaceID, attachmentID):
                guard let workspace = state.workspaces.first(where: { $0.id == workspaceID }),
                      let index = state.terminalAttachments[workspaceID]?.firstIndex(where: { $0.id == attachmentID }) else {
                    return .none
                }
                state.terminalAttachments[workspaceID]?[index].status = .uploading
                state.terminalAttachments[workspaceID]?[index].uploaded = nil
                state.terminalAttachments[workspaceID]?[index].error = nil
                guard let attachment = state.terminalAttachments[workspaceID]?[index] else { return .none }
                return uploadAttachmentEffect(state: state, workspace: workspace, attachment: attachment)

            case let .attachmentPickerFailed(message):
                state.errorMessage = message
                return .none

        default:
            return .none
        }
    }
}
