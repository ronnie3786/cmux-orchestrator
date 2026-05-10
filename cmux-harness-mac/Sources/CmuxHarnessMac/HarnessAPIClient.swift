import Foundation
import UniformTypeIdentifiers

enum HarnessAPIError: LocalizedError {
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

struct HarnessAPIClient {
    var baseURLString: String

    func status() async throws -> HarnessStatus {
        try await request(path: "/api/status")
    }

    func network() async throws -> NetworkResponse {
        try await request(path: "/api/network")
    }

    func log() async throws -> [LogEntry] {
        try await request(path: "/api/log")
    }

    func feed() async throws -> FeedResponse {
        try await request(path: "/api/feed")
    }

    func screen(index: Int, lines: Int = 500) async throws -> ScreenResponse {
        try await request(path: "/api/screen", queryItems: [
            URLQueryItem(name: "index", value: String(index)),
            URLQueryItem(name: "lines", value: String(lines))
        ])
    }

    func sendText(index: Int, text: String, surfaceId: String?) async throws -> BasicResponse {
        try await request(
            path: "/api/send",
            method: "POST",
            body: [
                "index": index,
                "text": text,
                "surfaceId": surfaceId ?? ""
            ]
        )
    }

    func sendKey(index: Int, key: String, surfaceId: String?) async throws -> BasicResponse {
        try await request(
            path: "/api/send",
            method: "POST",
            body: [
                "index": index,
                "key": key,
                "surfaceId": surfaceId ?? ""
            ]
        )
    }

    func setGlobalEnabled(_ enabled: Bool) async throws -> BasicResponse {
        try await request(
            path: "/api/toggle",
            method: "POST",
            body: ["enabled": enabled]
        )
    }

    func setWorkspaceAutoMode(index: Int, mode: WorkspaceAutoMode) async throws -> BasicResponse {
        try await request(
            path: "/api/workspace",
            method: "POST",
            body: [
                "index": index,
                "enabled": mode.isEnabled,
                "autoMode": mode.rawValue
            ]
        )
    }

    func setWorkspaceStarred(index: Int, starred: Bool) async throws -> BasicResponse {
        try await request(
            path: "/api/workspace-star",
            method: "POST",
            body: [
                "index": index,
                "starred": starred
            ]
        )
    }

    func renameWorkspace(index: Int, name: String) async throws -> BasicResponse {
        try await request(
            path: "/api/rename",
            method: "POST",
            body: [
                "index": index,
                "name": name
            ]
        )
    }

    func createSession(
        projectPath: String,
        branchName: String,
        jiraURL: String,
        prompt: String,
        mode: NewSessionMode,
        sessionName: String
    ) async throws -> NewSessionResponse {
        try await request(
            path: "/api/new-session",
            method: "POST",
            body: [
                "projectPath": projectPath,
                "branchName": mode == .shell ? "" : branchName,
                "jiraUrl": mode == .shell ? "" : jiraURL,
                "prompt": mode == .shell ? "" : prompt,
                "command": mode == .shell ? "zsh" : "claude",
                "sessionName": mode == .shell ? sessionName : ""
            ]
        )
    }

    func replyToFeed(_ item: FeedItem, action: String, mode: String? = nil, selections: [String]? = nil) async throws -> BasicResponse {
        try await request(
            path: "/api/feed/reply",
            method: "POST",
            body: [
                "requestID": item.requestID,
                "kind": item.kind,
                "action": action,
                "mode": mode ?? "",
                "selections": selections ?? []
            ]
        )
    }

    func gitStatus(index: Int) async throws -> GitStatus {
        try await request(path: "/api/git-status", queryItems: [
            URLQueryItem(name: "index", value: String(index))
        ])
    }

    func gitDiff(index: Int, file: String, section: String = "unstaged") async throws -> GitDiffResponse {
        try await request(
            path: "/api/git-diff",
            method: "POST",
            body: [
                "index": index,
                "file": file,
                "section": section
            ]
        )
    }

    func openGitFile(index: Int, file: String) async throws -> BasicResponse {
        try await request(path: "/api/git-open-file", method: "POST", body: ["index": index, "file": file])
    }

    func stageFile(index: Int, file: String) async throws -> BasicResponse {
        try await request(path: "/api/git-stage", method: "POST", body: ["index": index, "file": file])
    }

    func unstageFile(index: Int, file: String) async throws -> BasicResponse {
        try await request(path: "/api/git-unstage", method: "POST", body: ["index": index, "file": file])
    }

    func prComments(index: Int, includeResolved: Bool) async throws -> GitHubPRCommentsResponse {
        try await request(path: "/api/github/pr-comments", queryItems: [
            URLQueryItem(name: "index", value: String(index)),
            URLQueryItem(name: "includeResolved", value: includeResolved ? "true" : "false")
        ])
    }

    func jiraTickets(limit: Int = 50) async throws -> JiraTicketsResponse {
        try await request(path: "/api/jira/assigned", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ])
    }

    func jiraTicket(query: String) async throws -> JiraTicketResponse {
        try await request(path: "/api/jira/issue", queryItems: [
            URLQueryItem(name: "q", value: query)
        ])
    }

    func searchFiles(index: Int, query: String) async throws -> FileSearchResponse {
        try await request(path: "/api/file-search", queryItems: [
            URLQueryItem(name: "index", value: String(index)),
            URLQueryItem(name: "q", value: query)
        ])
    }

    func skills(index: Int) async throws -> SkillsResponse {
        try await request(path: "/api/skills", queryItems: [
            URLQueryItem(name: "index", value: String(index))
        ])
    }

    func uploadAttachment(workspace: Workspace, fileURL: URL, filename: String? = nil) async throws -> AttachmentUploadResponse {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let url = try makeURL(path: "/api/attachments", queryItems: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(workspace.index), forHTTPHeaderField: "X-Cmux-Workspace-Index")
        request.setValue(workspace.uuid, forHTTPHeaderField: "X-Cmux-Workspace-UUID")
        request.setValue(percentEncodedHeaderValue(filename ?? fileURL.lastPathComponent), forHTTPHeaderField: "X-Cmux-Filename")
        request.setValue(mimeType(for: fileURL), forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
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

    private func request<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Any? = nil
    ) async throws -> T {
        let url = try makeURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
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
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as HarnessAPIError {
            throw error
        } catch {
            throw HarnessAPIError.transport(error.localizedDescription)
        }
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        let normalized = Self.normalizedBaseURL(baseURLString)
        guard var components = URLComponents(string: normalized) else {
            throw HarnessAPIError.invalidURL
        }
        let requestPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = Self.apiBasePath(from: components.path)
        components.path = basePath.isEmpty ? "/\(requestPath)" : "/\(basePath)/\(requestPath)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw HarnessAPIError.invalidURL
        }
        return url
    }

    static func normalizedBaseURL(_ value: String) -> String {
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

    static func harnessURLFromHost(_ value: String, defaultPort: Int = 9091) -> String {
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
        let hostAndPort = host.contains(":") ? host : "\(host):\(defaultPort)"
        return "http://\(hostAndPort)/harness"
    }

    static func apiBasePath(from path: String) -> String {
        var basePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath == "harness" {
            basePath = ""
        } else if basePath.hasSuffix("/harness") {
            basePath.removeLast("/harness".count)
        }
        return basePath
    }

    private func percentEncodedHeaderValue(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment"
    }

    private func mimeType(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension),
              let mimeType = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mimeType
    }
}
