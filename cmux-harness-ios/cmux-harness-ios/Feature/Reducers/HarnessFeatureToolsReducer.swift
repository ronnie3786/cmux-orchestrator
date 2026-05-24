import ComposableArchitecture
import Foundation

extension HarnessFeature {
    func reduceTools(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
            case .loadSkills:
                guard let workspace = state.selectedWorkspace else { return .none }
                state.isLoadingSkills = !state.hasSkills
                state.skillsError = nil
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace] send in
                    do {
                        let response = try await client.skills(baseURLString, workspace.index)
                        await send(.skillsSucceeded(workspaceID: workspace.id, response))
                    } catch {
                        await send(.skillsFailed(HarnessAPI.message(for: error)))
                    }
                }

            case let .skillsSucceeded(workspaceID, response):
                guard state.selectedWorkspaceID == workspaceID else { return .none }
                state.isLoadingSkills = false
                state.skillsError = nil
                state.projectSkills = response.resolvedProjectSkills
                state.userSkills = response.resolvedUserSkills
                return .none

            case let .skillsFailed(message):
                state.isLoadingSkills = false
                state.skillsError = message
                return .none

            case let .appendSkillInvocation(skill):
                appendSkillInvocation(skill, prefix: "/", state: &state)
                return .none

            case let .appendCodexSkillInvocation(skill):
                appendSkillInvocation(skill, prefix: "$", state: &state)
                return .none

            case let .appendSkillFilePath(skill):
                state.detailDraft = appendPromptToken("`\(skill.skillFilePath)`", to: state.detailDraft)
                persistDetailDraft(&state)
                state.detailTab = .terminal
                state.detailInputFocusRequest += 1
                return .none

            case .fileSearchTapped:
                state.isShowingFileSearch = true
                state.fileSearchQuery = ""
                state.fileSearchResults = []
                state.fileSearchError = nil
                state.isSearchingFiles = false
                return .cancel(id: fileSearchCancelID)

            case .dismissFileSearch:
                state.isShowingFileSearch = false
                state.fileSearchQuery = ""
                state.fileSearchResults = []
                state.fileSearchError = nil
                state.isSearchingFiles = false
                return .cancel(id: fileSearchCancelID)

            case let .fileSearchQueryChanged(query):
                state.fileSearchQuery = query
                state.fileSearchError = nil
                let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedQuery.count >= 3, let workspace = state.selectedWorkspace else {
                    state.fileSearchResults = []
                    state.isSearchingFiles = false
                    return .cancel(id: fileSearchCancelID)
                }
                state.isSearchingFiles = true
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace, trimmedQuery] send in
                    do {
                        let response = try await client.searchFiles(baseURLString, workspace.index, trimmedQuery)
                        await send(.fileSearchSucceeded(workspaceID: workspace.id, query: trimmedQuery, response))
                    } catch {
                        await send(.fileSearchFailed(query: trimmedQuery, message: HarnessAPI.message(for: error)))
                    }
                }
                .cancellable(id: fileSearchCancelID, cancelInFlight: true)

            case let .fileSearchSucceeded(workspaceID, query, response):
                guard state.selectedWorkspaceID == workspaceID,
                      state.fileSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return .none
                }
                state.isSearchingFiles = false
                state.fileSearchError = nil
                state.fileSearchResults = response.files
                return .none

            case let .fileSearchFailed(query, message):
                guard state.fileSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return .none
                }
                state.isSearchingFiles = false
                state.fileSearchError = message
                return .none

            case let .appendFilePath(file):
                state.detailDraft = appendPromptToken("`\(file.path)`", to: state.detailDraft)
                persistDetailDraft(&state)
                state.detailTab = .terminal
                state.detailInputFocusRequest += 1
                state.isShowingFileSearch = false
                state.fileSearchQuery = ""
                state.fileSearchResults = []
                state.fileSearchError = nil
                state.isSearchingFiles = false
                return .cancel(id: fileSearchCancelID)

            case .jiraTicketsTapped:
                state.isShowingJiraTickets = true
                state.jiraTicketsError = nil
                state.isLoadingJiraTickets = state.jiraTickets.isEmpty
                state.jiraLookupError = nil
                return .send(.loadAssignedJiraTickets)

            case .dismissJiraTickets:
                state.isShowingJiraTickets = false
                state.jiraTicketsError = nil
                state.isLoadingJiraTickets = false
                state.jiraLookupQuery = ""
                state.resolvedJiraTicket = nil
                state.jiraLookupError = nil
                state.isResolvingJiraTicket = false
                return .merge(
                    .cancel(id: jiraTicketsCancelID),
                    .cancel(id: jiraLookupCancelID)
                )

            case .loadAssignedJiraTickets:
                state.isLoadingJiraTickets = true
                state.jiraTicketsError = nil
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString] send in
                    do {
                        let response = try await client.assignedJiraTickets(baseURLString, nil, 50)
                        await send(.assignedJiraTicketsSucceeded(response))
                    } catch {
                        await send(.assignedJiraTicketsFailed(HarnessAPI.message(for: error)))
                    }
                }
                .cancellable(id: jiraTicketsCancelID, cancelInFlight: true)

            case let .assignedJiraTicketsSucceeded(response):
                state.isLoadingJiraTickets = false
                state.jiraTicketsError = nil
                state.jiraTickets = response.tickets.sorted { lhs, rhs in
                    lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
                }
                return .none

            case let .assignedJiraTicketsFailed(message):
                state.isLoadingJiraTickets = false
                state.jiraTicketsError = message
                return .none

            case let .jiraLookupQueryChanged(query):
                state.jiraLookupQuery = query
                state.resolvedJiraTicket = nil
                state.jiraLookupError = nil
                return .none

            case .resolveJiraTicket:
                let query = state.jiraLookupQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else {
                    state.jiraLookupError = "Enter a Jira key or URL"
                    state.resolvedJiraTicket = nil
                    return .none
                }
                state.isResolvingJiraTicket = true
                state.jiraLookupError = nil
                state.resolvedJiraTicket = nil
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, query] send in
                    do {
                        let response = try await client.jiraTicket(baseURLString, query)
                        await send(.jiraTicketResolved(response))
                    } catch {
                        await send(.jiraTicketResolveFailed(HarnessAPI.message(for: error)))
                    }
                }
                .cancellable(id: jiraLookupCancelID, cancelInFlight: true)

            case let .jiraTicketResolved(response):
                state.isResolvingJiraTicket = false
                if let ticket = response.ticket {
                    state.resolvedJiraTicket = ticket
                    state.jiraLookupQuery = ticket.key
                    state.jiraLookupError = nil
                } else {
                    state.resolvedJiraTicket = nil
                    state.jiraLookupError = response.error ?? "Jira ticket not found"
                }
                return .none

            case let .jiraTicketResolveFailed(message):
                state.isResolvingJiraTicket = false
                state.resolvedJiraTicket = nil
                state.jiraLookupError = message
                return .none

            case let .appendJiraTicketReference(ticket):
                state.detailDraft = appendPromptBlock(formatJiraTicketPrompt(ticket), to: state.detailDraft)
                persistDetailDraft(&state)
                state.detailTab = .terminal
                state.detailInputFocusRequest += 1
                state.isShowingJiraTickets = false
                state.jiraTicketsError = nil
                state.isLoadingJiraTickets = false
                state.jiraLookupQuery = ""
                state.resolvedJiraTicket = nil
                state.jiraLookupError = nil
                state.isResolvingJiraTicket = false
                return .merge(
                    .cancel(id: jiraTicketsCancelID),
                    .cancel(id: jiraLookupCancelID)
                )

        default:
            return .none
        }
    }
}

private func appendSkillInvocation(_ skill: ProjectSkill, prefix: String, state: inout HarnessFeature.State) {
    state.detailDraft = appendPromptToken("\(prefix)\(skill.name)", to: state.detailDraft)
    persistDetailDraft(&state)
    state.detailTab = .terminal
    state.detailInputFocusRequest += 1
}
