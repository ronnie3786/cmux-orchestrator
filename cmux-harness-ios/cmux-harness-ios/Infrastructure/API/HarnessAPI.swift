import Foundation
import UniformTypeIdentifiers

enum HarnessAPIError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case server(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL"
        case let .server(message):
            return message
        case let .transport(message):
            return message
        }
    }
}

enum HarnessAPI {
    static let jsonContentType = "application/json"
    static let attachmentMaxBytes: Int64 = 20 * 1024 * 1024

    static func status(baseURLString: String) async throws -> HarnessStatus {
        try await request(baseURLString: baseURLString, path: "/api/status")
    }

    static func log(baseURLString: String) async throws -> [LogEntry] {
        try await request(baseURLString: baseURLString, path: "/api/log")
    }

    static func notifications(baseURLString: String) async throws -> NotificationsResponse {
        try await request(baseURLString: baseURLString, path: "/api/notifications")
    }

    static func feed(baseURLString: String) async throws -> FeedResponse {
        try await request(baseURLString: baseURLString, path: "/api/feed")
    }

    static func replyToFeed(
        baseURLString: String,
        requestID: String,
        kind: String,
        action: String?,
        mode: String?,
        selections: [String]?
    ) async throws -> BasicResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/feed/reply",
            method: "POST",
            body: FeedReplyRequest(
                requestID: requestID,
                kind: kind,
                action: action,
                mode: mode,
                selections: selections
            )
        )
    }

    static func screen(baseURLString: String, index: Int, lines: Int) async throws -> ScreenResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/screen",
            queryItems: [
                URLQueryItem(name: "index", value: String(index)),
                URLQueryItem(name: "lines", value: String(lines)),
            ]
        )
    }

    static func setGlobalEnabled(baseURLString: String, enabled: Bool) async throws -> BasicResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/toggle",
            method: "POST",
            body: ToggleRequest(enabled: enabled)
        )
    }

    static func setWorkspaceEnabled(
        baseURLString: String,
        index: Int,
        enabled: Bool
    ) async throws -> BasicResponse {
        try await setWorkspaceAutoMode(
            baseURLString: baseURLString,
            index: index,
            mode: enabled ? .auto : .off
        )
    }

    static func setWorkspaceAutoMode(
        baseURLString: String,
        index: Int,
        mode: WorkspaceAutoMode
    ) async throws -> BasicResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/workspace",
            method: "POST",
            body: WorkspaceToggleRequest(index: index, enabled: mode.isEnabled, autoMode: mode.rawValue)
        )
    }

    static func setWorkspaceStarred(
        baseURLString: String,
        index: Int,
        starred: Bool
    ) async throws -> BasicResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/workspace-star",
            method: "POST",
            body: WorkspaceStarRequest(index: index, starred: starred)
        )
    }

    static func renameWorkspace(
        baseURLString: String,
        index: Int,
        name: String
    ) async throws -> BasicResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/rename",
            method: "POST",
            body: RenameRequest(index: index, name: name)
        )
    }

    static func sendText(
        baseURLString: String,
        index: Int,
        text: String,
        surfaceId: String?
    ) async throws -> BasicResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/send",
            method: "POST",
            body: SendRequest(index: index, text: text, key: nil, surfaceId: surfaceId)
        )
    }

    static func sendKey(
        baseURLString: String,
        index: Int,
        key: HarnessKey,
        surfaceId: String?
    ) async throws -> BasicResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/send",
            method: "POST",
            body: SendRequest(index: index, text: nil, key: key.rawValue, surfaceId: surfaceId)
        )
    }

    static func createSession(
        baseURLString: String,
        projectPath: String,
        branchName: String,
        jiraURL: String,
        prompt: String,
        mode: NewSessionMode,
        sessionName: String
    ) async throws -> NewSessionResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/new-session",
            method: "POST",
            body: NewSessionRequest(
                projectPath: projectPath,
                branchName: mode == .shell ? "" : branchName,
                jiraUrl: mode == .shell ? "" : jiraURL,
                prompt: mode == .shell ? "" : prompt,
                command: mode == .shell ? "zsh" : "claude",
                sessionName: mode == .shell ? sessionName : ""
            )
        )
    }

    static func gitStatus(baseURLString: String, index: Int) async throws -> GitStatus {
        try await request(
            baseURLString: baseURLString,
            path: "/api/git-status",
            queryItems: [URLQueryItem(name: "index", value: String(index))]
        )
    }

    static func stageFile(baseURLString: String, index: Int, file: String) async throws -> BasicResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/git-stage",
            method: "POST",
            body: GitFileRequest(index: index, file: file)
        )
    }

    static func unstageFile(baseURLString: String, index: Int, file: String) async throws -> BasicResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/git-unstage",
            method: "POST",
            body: GitFileRequest(index: index, file: file)
        )
    }

    static func diff(
        baseURLString: String,
        index: Int,
        file: String,
        section: GitFileSection
    ) async throws -> GitDiffResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/git-diff",
            method: "POST",
            body: GitDiffRequest(index: index, file: file, section: section.rawValue)
        )
    }

    static func githubPRComments(
        baseURLString: String,
        index: Int,
        includeResolved: Bool = false
    ) async throws -> GitHubPRCommentsResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/github/pr-comments",
            queryItems: [
                URLQueryItem(name: "index", value: String(index)),
                URLQueryItem(name: "includeResolved", value: includeResolved ? "true" : "false"),
            ]
        )
    }

    static func skills(baseURLString: String, index: Int) async throws -> SkillsResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/skills",
            queryItems: [URLQueryItem(name: "index", value: String(index))]
        )
    }

    static func searchFiles(baseURLString: String, index: Int, query: String) async throws -> FileSearchResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/file-search",
            queryItems: [
                URLQueryItem(name: "index", value: String(index)),
                URLQueryItem(name: "q", value: query),
            ]
        )
    }

    static func assignedJiraTickets(
        baseURLString: String,
        project: String? = nil,
        limit: Int = 50
    ) async throws -> JiraTicketsResponse {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let project = project?.trimmingCharacters(in: .whitespacesAndNewlines),
           !project.isEmpty {
            queryItems.append(URLQueryItem(name: "project", value: project))
        }
        return try await request(
            baseURLString: baseURLString,
            path: "/api/jira/assigned",
            queryItems: queryItems
        )
    }

    static func jiraTicket(
        baseURLString: String,
        query: String
    ) async throws -> JiraTicketResponse {
        return try await request(
            baseURLString: baseURLString,
            path: "/api/jira/issue",
            queryItems: [
                URLQueryItem(name: "q", value: query),
            ]
        )
    }

    static func uploadAttachment(
        baseURLString: String,
        workspaceIndex: Int,
        workspaceUUID: String,
        fileURL: URL,
        filename: String? = nil
    ) async throws -> AttachmentUploadResponse {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let byteCount = try fileByteCount(fileURL)
        guard byteCount > 0 else {
            throw HarnessAPIError.server("File is empty")
        }
        guard byteCount <= attachmentMaxBytes else {
            throw HarnessAPIError.server("File exceeds 20 MB limit")
        }

        let url = try makeURL(baseURLString: baseURLString, path: "/api/attachments", queryItems: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(jsonContentType, forHTTPHeaderField: "Accept")
        request.setValue(String(workspaceIndex), forHTTPHeaderField: "X-Cmux-Workspace-Index")
        request.setValue(workspaceUUID, forHTTPHeaderField: "X-Cmux-Workspace-UUID")
        request.setValue(
            percentEncodedHeaderValue(filename?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? filename! : fileURL.lastPathComponent),
            forHTTPHeaderField: "X-Cmux-Filename"
        )
        request.setValue(mimeType(for: fileURL), forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await uploadWithTimeout(request: request, fileURL: fileURL)
            guard let http = response as? HTTPURLResponse else {
                throw HarnessAPIError.transport("No HTTP response")
            }
            guard 200..<300 ~= http.statusCode else {
                if let envelope = try? JSONDecoder().decode(BasicResponse.self, from: data),
                   let message = envelope.error {
                    throw HarnessAPIError.server(message)
                }
                throw HarnessAPIError.server("HTTP \(http.statusCode)")
            }

            let decoded = try JSONDecoder().decode(AttachmentUploadResponse.self, from: data)
            if !decoded.ok {
                throw HarnessAPIError.server(decoded.error ?? "Attachment upload failed")
            }
            return decoded
        } catch let error as HarnessAPIError {
            throw error
        } catch {
            throw HarnessAPIError.transport(error.localizedDescription)
        }
    }

    static func registerPushDevice(
        baseURLString: String,
        token: String,
        bundleID: String,
        environment: String
    ) async throws -> BasicResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/push/register",
            method: "POST",
            body: PushDeviceRegistrationRequest(
                token: token,
                bundleId: bundleID,
                environment: environment
            )
        )
    }

    static func clearPushApproval(
        baseURLString: String,
        workspaceID: String,
        workspaceUUID: String,
        surfaceID: String?
    ) async throws -> BasicResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/push/clear",
            method: "POST",
            body: PushApprovalClearRequest(
                workspaceID: workspaceID,
                workspaceUUID: workspaceUUID,
                surfaceID: surfaceID ?? ""
            )
        )
    }

    nonisolated static func message(for error: Error) -> String {
        if let apiError = error as? HarnessAPIError {
            return apiError.localizedDescription
        }
        return error.localizedDescription
    }

    nonisolated static func normalizedBaseURL(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }
        if !trimmed.contains("://") {
            trimmed = "http://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    nonisolated static func harnessURLFromHost(_ value: String, defaultPort: Int = 9091) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("://") {
            return normalizedBaseURL(trimmed)
        }

        var host = trimmed
        if let slashIndex = host.firstIndex(of: "/") {
            host = String(host[..<slashIndex])
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty else { return "" }

        let needsPort = !host.contains(":")
        let hostAndPort = needsPort ? "\(host):\(defaultPort)" : host
        return "http://\(hostAndPort)/harness"
    }
}
