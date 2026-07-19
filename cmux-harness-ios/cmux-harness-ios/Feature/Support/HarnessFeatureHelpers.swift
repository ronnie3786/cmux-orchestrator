import Foundation

func trimDrafts(_ state: inout HarnessFeature.State) {
    let activeIDs = Set(state.workspaces.map(\.id))
    state.draftMessages = state.draftMessages.filter { activeIDs.contains($0.key) }
    state.terminalAttachments = state.terminalAttachments.filter { activeIDs.contains($0.key) }
}

func loadDetailDraft(for workspaceID: String?, into state: inout HarnessFeature.State) {
    state.detailDraft = workspaceID.flatMap { state.detailDrafts[$0] } ?? ""
}

func persistDetailDraft(_ state: inout HarnessFeature.State) {
    guard let workspaceID = state.selectedWorkspaceID else { return }
    if state.detailDraft.isEmpty {
        state.detailDrafts.removeValue(forKey: workspaceID)
    } else {
        state.detailDrafts[workspaceID] = state.detailDraft
    }
    guard !state.isDemoMode else { return }
    HarnessSettingsStore.detailDrafts = state.detailDrafts
}

func feedItem(_ item: FeedItem, matches workspace: Workspace) -> Bool {
    let workspaceID = trimmedNonEmpty(item.workspaceID)
    let surfaceID = trimmedNonEmpty(item.surfaceID)
    let workspaceMatches = workspaceID.map { $0 == workspace.uuid || $0 == workspace.id }
    let surfaceMatches = surfaceID.map { $0 == workspace.surfaceId || $0 == workspace.surfaceUuid }

    if let surfaceMatches {
        guard surfaceMatches else { return false }
        return workspaceMatches ?? true
    }
    return workspaceMatches ?? false
}

func feedItems(for workspace: Workspace, in state: HarnessFeature.State) -> [FeedItem] {
    state.feedItems.filter { feedItem($0, matches: workspace) }
}

func jiraKey(from value: String) -> String? {
    let pattern = #"([A-Z]+-\d+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return nil
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = regex.firstMatch(in: value, range: range),
          let matchRange = Range(match.range(at: 1), in: value) else {
        return nil
    }
    return String(value[matchRange]).uppercased()
}

func appendPromptToken(_ token: String, to draft: String) -> String {
    guard !draft.isEmpty else { return token }
    if draft.last?.isWhitespace == true {
        return draft + token
    }
    return draft + " " + token
}

func appendPromptBlock(_ block: String, to draft: String) -> String {
    let trimmedBlock = block.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedDraft.isEmpty else { return trimmedBlock }
    return trimmedDraft + "\n\n" + trimmedBlock
}

func trimmedNonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

func workspaceDirectory(for workspace: Workspace) -> String? {
    trimmedNonEmpty(workspace.cwd)
}

func shellSessionName(for workspace: Workspace) -> String {
    let baseName = workspace.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !baseName.isEmpty else { return "_ Shell" }
    if baseName.range(of: "shell", options: [.caseInsensitive, .diacriticInsensitive]) != nil {
        return "_ \(baseName)"
    }
    return "_ \(baseName) Shell"
}

func pendingCreatedWorkspaceSelection(
    from response: NewSessionResponse
) -> PendingCreatedWorkspaceSelection? {
    let uuid = trimmedNonEmpty(response.workspace?.uuid)
    let index = response.workspace?.index
    guard uuid != nil || index != nil else { return nil }
    return PendingCreatedWorkspaceSelection(uuid: uuid, index: index)
}

func formatPRCommentThreadPrompt(
    thread: GitHubPRThread,
    response: GitHubPRCommentsResponse?
) -> String {
    thread.promptReference(pullRequest: response?.pullRequest)
}

func formatJiraTicketPrompt(_ ticket: JiraTicket) -> String {
    var lines = [
        "Jira: \(ticket.key)",
        "Title: \(ticket.title.isEmpty ? "(no title)" : ticket.title)",
        "URL: \(ticket.url)",
    ]
    if !ticket.status.isEmpty {
        lines.append("Status: \(ticket.status)")
    }
    if !ticket.priority.isEmpty {
        lines.append("Priority: \(ticket.priority)")
    }
    if !ticket.issueType.isEmpty {
        lines.append("Type: \(ticket.issueType)")
    }
    lines.append("")
    lines.append("Please use this ticket as context.")
    return lines.joined(separator: "\n")
}

func formatDiffLineReviewPrompt(_ reviewComment: DiffLineReviewComment) -> String {
    let comment = reviewComment.comment.trimmingCharacters(in: .whitespacesAndNewlines)
    let code = reviewComment.code.isEmpty ? "(blank line)" : reviewComment.code
    let line = reviewComment.lineNumber.map {
        "\($0) (\(reviewComment.side.promptLabel))"
    } ?? reviewComment.side.promptLabel

    return """
    Please address this review comment:

    File: \(reviewComment.file)
    Line: \(line)
    Code: \(code)
    Comment: \(comment)
    """
}

func matchingWorkspaceID(
    for notification: PushApprovalNotification,
    in state: HarnessFeature.State
) -> String? {
    if !notification.workspaceID.isEmpty,
       state.workspaces.contains(where: { $0.id == notification.workspaceID }) {
        return notification.workspaceID
    }
    if !notification.workspaceUUID.isEmpty, !notification.surfaceID.isEmpty,
       let match = state.workspaces.first(where: {
           $0.uuid == notification.workspaceUUID && $0.surfaceId == notification.surfaceID
       }) {
        return match.id
    }
    if !notification.workspaceUUID.isEmpty,
       let match = state.workspaces.first(where: { $0.uuid == notification.workspaceUUID }) {
        return match.id
    }
    return nil
}

func matchingWorkspaceID(
    for selection: PendingCreatedWorkspaceSelection,
    in state: HarnessFeature.State
) -> String? {
    if let uuid = selection.uuid,
       let match = state.workspaces.first(where: { $0.uuid == uuid }) {
        return match.id
    }
    if let index = selection.index,
       let match = state.workspaces.first(where: { $0.index == index }) {
        return match.id
    }
    return nil
}

extension Workspace {
    var pushWorkspaceID: String {
        if let surfaceId, !surfaceId.isEmpty {
            return "\(uuid)|\(surfaceId)"
        }
        return uuid
    }
}
