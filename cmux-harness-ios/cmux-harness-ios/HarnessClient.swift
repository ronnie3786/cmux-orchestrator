import ComposableArchitecture
import Foundation

struct HarnessClient: Sendable {
    var discoverServers: @Sendable () async -> [DiscoveredHarnessServer]
    var probeServer: @Sendable (String) async -> Bool
    var status: @Sendable (String) async throws -> HarnessStatus
    var log: @Sendable (String) async throws -> [LogEntry]
    var screen: @Sendable (String, Int, Int) async throws -> ScreenResponse
    var setGlobalEnabled: @Sendable (String, Bool) async throws -> BasicResponse
    var setWorkspaceEnabled: @Sendable (String, Int, Bool) async throws -> BasicResponse
    var setWorkspaceAutoMode: @Sendable (String, Int, WorkspaceAutoMode) async throws -> BasicResponse
    var setWorkspaceStarred: @Sendable (String, Int, Bool) async throws -> BasicResponse
    var renameWorkspace: @Sendable (String, Int, String) async throws -> BasicResponse
    var sendText: @Sendable (String, Int, String, String?) async throws -> BasicResponse
    var sendKey: @Sendable (String, Int, HarnessKey, String?) async throws -> BasicResponse
    var createSession: @Sendable (
        String,
        String,
        String,
        String,
        String,
        NewSessionMode,
        String
    ) async throws -> NewSessionResponse
    var gitStatus: @Sendable (String, Int) async throws -> GitStatus
    var stageFile: @Sendable (String, Int, String) async throws -> BasicResponse
    var unstageFile: @Sendable (String, Int, String) async throws -> BasicResponse
    var diff: @Sendable (String, Int, String, GitFileSection) async throws -> GitDiffResponse
    var githubPRComments: @Sendable (String, Int, Bool) async throws -> GitHubPRCommentsResponse
    var skills: @Sendable (String, Int) async throws -> SkillsResponse
    var searchFiles: @Sendable (String, Int, String) async throws -> FileSearchResponse
    var assignedJiraTickets: @Sendable (String, String, Int) async throws -> JiraTicketsResponse
    var uploadAttachment: @Sendable (String, Int, String, URL, String?) async throws -> AttachmentUploadResponse
    var clearPushApproval: @Sendable (String, String, String, String?) async throws -> BasicResponse
}

extension HarnessClient {
    nonisolated static let live = Self(
        discoverServers: {
            await HarnessServerDiscovery.discover()
        },
        probeServer: { baseURLString in
            do {
                _ = try await HarnessAPI.status(baseURLString: baseURLString)
                return true
            } catch {
                return false
            }
        },
        status: { baseURLString in
            try await HarnessAPI.status(baseURLString: baseURLString)
        },
        log: { baseURLString in
            try await HarnessAPI.log(baseURLString: baseURLString)
        },
        screen: { baseURLString, index, lines in
            try await HarnessAPI.screen(baseURLString: baseURLString, index: index, lines: lines)
        },
        setGlobalEnabled: { baseURLString, enabled in
            try await HarnessAPI.setGlobalEnabled(baseURLString: baseURLString, enabled: enabled)
        },
        setWorkspaceEnabled: { baseURLString, index, enabled in
            try await HarnessAPI.setWorkspaceEnabled(baseURLString: baseURLString, index: index, enabled: enabled)
        },
        setWorkspaceAutoMode: { baseURLString, index, mode in
            try await HarnessAPI.setWorkspaceAutoMode(baseURLString: baseURLString, index: index, mode: mode)
        },
        setWorkspaceStarred: { baseURLString, index, starred in
            try await HarnessAPI.setWorkspaceStarred(baseURLString: baseURLString, index: index, starred: starred)
        },
        renameWorkspace: { baseURLString, index, name in
            try await HarnessAPI.renameWorkspace(baseURLString: baseURLString, index: index, name: name)
        },
        sendText: { baseURLString, index, text, surfaceId in
            try await HarnessAPI.sendText(baseURLString: baseURLString, index: index, text: text, surfaceId: surfaceId)
        },
        sendKey: { baseURLString, index, key, surfaceId in
            try await HarnessAPI.sendKey(baseURLString: baseURLString, index: index, key: key, surfaceId: surfaceId)
        },
        createSession: { baseURLString, projectPath, branchName, jiraURL, prompt, mode, sessionName in
            try await HarnessAPI.createSession(
                baseURLString: baseURLString,
                projectPath: projectPath,
                branchName: branchName,
                jiraURL: jiraURL,
                prompt: prompt,
                mode: mode,
                sessionName: sessionName
            )
        },
        gitStatus: { baseURLString, index in
            try await HarnessAPI.gitStatus(baseURLString: baseURLString, index: index)
        },
        stageFile: { baseURLString, index, file in
            try await HarnessAPI.stageFile(baseURLString: baseURLString, index: index, file: file)
        },
        unstageFile: { baseURLString, index, file in
            try await HarnessAPI.unstageFile(baseURLString: baseURLString, index: index, file: file)
        },
        diff: { baseURLString, index, file, section in
            try await HarnessAPI.diff(baseURLString: baseURLString, index: index, file: file, section: section)
        },
        githubPRComments: { baseURLString, index, includeResolved in
            try await HarnessAPI.githubPRComments(
                baseURLString: baseURLString,
                index: index,
                includeResolved: includeResolved
            )
        },
        skills: { baseURLString, index in
            try await HarnessAPI.skills(baseURLString: baseURLString, index: index)
        },
        searchFiles: { baseURLString, index, query in
            try await HarnessAPI.searchFiles(baseURLString: baseURLString, index: index, query: query)
        },
        assignedJiraTickets: { baseURLString, project, limit in
            try await HarnessAPI.assignedJiraTickets(baseURLString: baseURLString, project: project, limit: limit)
        },
        uploadAttachment: { baseURLString, workspaceIndex, workspaceUUID, fileURL, filename in
            try await HarnessAPI.uploadAttachment(
                baseURLString: baseURLString,
                workspaceIndex: workspaceIndex,
                workspaceUUID: workspaceUUID,
                fileURL: fileURL,
                filename: filename
            )
        },
        clearPushApproval: { baseURLString, workspaceID, workspaceUUID, surfaceID in
            try await HarnessAPI.clearPushApproval(
                baseURLString: baseURLString,
                workspaceID: workspaceID,
                workspaceUUID: workspaceUUID,
                surfaceID: surfaceID
            )
        }
    )
}

enum HarnessClientError: Error, Equatable, Sendable {
    case unimplemented(String)
}

extension HarnessClient {
    nonisolated static let unimplemented = Self(
        discoverServers: { [] },
        probeServer: { _ in false },
        status: { _ in throw HarnessClientError.unimplemented("status") },
        log: { _ in throw HarnessClientError.unimplemented("log") },
        screen: { _, _, _ in throw HarnessClientError.unimplemented("screen") },
        setGlobalEnabled: { _, _ in throw HarnessClientError.unimplemented("setGlobalEnabled") },
        setWorkspaceEnabled: { _, _, _ in throw HarnessClientError.unimplemented("setWorkspaceEnabled") },
        setWorkspaceAutoMode: { _, _, _ in throw HarnessClientError.unimplemented("setWorkspaceAutoMode") },
        setWorkspaceStarred: { _, _, _ in throw HarnessClientError.unimplemented("setWorkspaceStarred") },
        renameWorkspace: { _, _, _ in throw HarnessClientError.unimplemented("renameWorkspace") },
        sendText: { _, _, _, _ in throw HarnessClientError.unimplemented("sendText") },
        sendKey: { _, _, _, _ in throw HarnessClientError.unimplemented("sendKey") },
        createSession: { _, _, _, _, _, _, _ in throw HarnessClientError.unimplemented("createSession") },
        gitStatus: { _, _ in throw HarnessClientError.unimplemented("gitStatus") },
        stageFile: { _, _, _ in throw HarnessClientError.unimplemented("stageFile") },
        unstageFile: { _, _, _ in throw HarnessClientError.unimplemented("unstageFile") },
        diff: { _, _, _, _ in throw HarnessClientError.unimplemented("diff") },
        githubPRComments: { _, _, _ in throw HarnessClientError.unimplemented("githubPRComments") },
        skills: { _, _ in throw HarnessClientError.unimplemented("skills") },
        searchFiles: { _, _, _ in throw HarnessClientError.unimplemented("searchFiles") },
        assignedJiraTickets: { _, _, _ in throw HarnessClientError.unimplemented("assignedJiraTickets") },
        uploadAttachment: { _, _, _, _, _ in throw HarnessClientError.unimplemented("uploadAttachment") },
        clearPushApproval: { _, _, _, _ in throw HarnessClientError.unimplemented("clearPushApproval") }
    )
}

private enum HarnessClientKey: DependencyKey {
    static let liveValue = HarnessClient.live
    static let testValue = HarnessClient.unimplemented
}

extension DependencyValues {
    var harnessClient: HarnessClient {
        get { self[HarnessClientKey.self] }
        set { self[HarnessClientKey.self] = newValue }
    }
}
