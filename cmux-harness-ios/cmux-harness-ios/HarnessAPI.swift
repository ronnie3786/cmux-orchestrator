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
    private static let jsonContentType = "application/json"
    static let attachmentMaxBytes: Int64 = 20 * 1024 * 1024

    static func status(baseURLString: String) async throws -> HarnessStatus {
        try await request(baseURLString: baseURLString, path: "/api/status")
    }

    static func log(baseURLString: String) async throws -> [LogEntry] {
        try await request(baseURLString: baseURLString, path: "/api/log")
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
        try await request(
            baseURLString: baseURLString,
            path: "/api/workspace",
            method: "POST",
            body: WorkspaceToggleRequest(index: index, enabled: enabled)
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
        project: String = "IOSDOX",
        limit: Int = 50
    ) async throws -> JiraTicketsResponse {
        try await request(
            baseURLString: baseURLString,
            path: "/api/jira/assigned",
            queryItems: [
                URLQueryItem(name: "project", value: project),
                URLQueryItem(name: "limit", value: String(limit)),
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

    static func normalizedBaseURL(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            trimmed = HarnessSettingsStore.defaultServerURL
        }
        if !trimmed.contains("://") {
            trimmed = "http://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func request<T: Decodable>(
        baseURLString: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: (any Encodable)? = nil
    ) async throws -> T {
        let url = try makeURL(baseURLString: baseURLString, path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(jsonContentType, forHTTPHeaderField: "Accept")

        if let body {
            request.setValue(jsonContentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
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

            let decoded = try JSONDecoder().decode(T.self, from: data)
            if let basic = decoded as? BasicResponse, !basic.ok {
                throw HarnessAPIError.server(basic.error ?? "Request failed")
            }
            if let screen = decoded as? ScreenResponse, !screen.ok {
                throw HarnessAPIError.server(screen.error ?? "Screen request failed")
            }
            if let diff = decoded as? GitDiffResponse, !diff.ok {
                throw HarnessAPIError.server(diff.error ?? "Diff request failed")
            }
            if let session = decoded as? NewSessionResponse, !session.ok {
                throw HarnessAPIError.server(session.error ?? "Session creation failed")
            }
            if let git = decoded as? GitStatus, git.ok == false {
                throw HarnessAPIError.server(git.error ?? "Git status failed")
            }
            if let skills = decoded as? SkillsResponse, !skills.ok {
                throw HarnessAPIError.server(skills.error ?? "Skills request failed")
            }
            if let fileSearch = decoded as? FileSearchResponse, !fileSearch.ok {
                throw HarnessAPIError.server(fileSearch.error ?? "File search failed")
            }
            if let jiraTickets = decoded as? JiraTicketsResponse, !jiraTickets.ok {
                throw HarnessAPIError.server(jiraTickets.error ?? "Jira tickets request failed")
            }
            return decoded
        } catch let error as HarnessAPIError {
            throw error
        } catch {
            throw HarnessAPIError.transport(error.localizedDescription)
        }
    }

    private static func uploadWithTimeout(request: URLRequest, fileURL: URL) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                try await URLSession.shared.upload(for: request, fromFile: fileURL)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw HarnessAPIError.transport("Attachment upload timed out")
            }
            guard let result = try await group.next() else {
                throw HarnessAPIError.transport("Attachment upload failed")
            }
            group.cancelAll()
            return result
        }
    }

    private static func fileByteCount(_ url: URL) throws -> Int64 {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return Int64(size)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber {
            return size.int64Value
        }
        return 0
    }

    private static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              let mimeType = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mimeType
    }

    private static func percentEncodedHeaderValue(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment"
    }

    static func makeURL(
        baseURLString: String,
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        let normalized = normalizedBaseURL(baseURLString)
        guard var components = URLComponents(string: normalized) else {
            throw HarnessAPIError.invalidURL
        }

        let basePath = apiBasePath(from: components.path)
        let requestPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.isEmpty {
            components.path = "/" + requestPath
        } else {
            components.path = "/" + [basePath, requestPath].joined(separator: "/")
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw HarnessAPIError.invalidURL
        }
        return url
    }

    private static func apiBasePath(from path: String) -> String {
        var basePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath == "harness" {
            basePath = ""
        } else if basePath.hasSuffix("/harness") {
            basePath.removeLast("/harness".count)
        }
        return basePath
    }
}

enum HarnessSettingsStore {
    static let defaultServerURL = "http://doximity-m4.tail1db61d.ts.net:9091/harness"
    private static let legacyDefaultServerURL = "http://localhost:9091"
    private static let defaultMigrationKey = "cmuxHarnessTailnetDefaultMigrated"
    private static let serverURLKey = "cmuxHarnessServerURL"
    private static let lastSelectedWorkspaceIDKey = "cmuxHarnessLastSelectedWorkspaceID"
    private static let detailDraftsKey = "cmuxHarnessDetailDrafts"

    static var serverURL: String {
        get {
            guard let value = UserDefaults.standard.string(forKey: serverURLKey) else {
                return HarnessAPI.normalizedBaseURL(defaultServerURL)
            }
            let normalized = HarnessAPI.normalizedBaseURL(value)
            if normalized == legacyDefaultServerURL, !UserDefaults.standard.bool(forKey: defaultMigrationKey) {
                let replacement = HarnessAPI.normalizedBaseURL(defaultServerURL)
                UserDefaults.standard.set(replacement, forKey: serverURLKey)
                UserDefaults.standard.set(true, forKey: defaultMigrationKey)
                return replacement
            }
            return normalized
        }
        set {
            UserDefaults.standard.set(HarnessAPI.normalizedBaseURL(newValue), forKey: serverURLKey)
            UserDefaults.standard.set(true, forKey: defaultMigrationKey)
        }
    }

    static var lastSelectedWorkspaceID: String? {
        get {
            guard let value = UserDefaults.standard.string(forKey: lastSelectedWorkspaceIDKey),
                  !value.isEmpty else {
                return nil
            }
            return value
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: lastSelectedWorkspaceIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastSelectedWorkspaceIDKey)
            }
        }
    }

    static var detailDrafts: [String: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: detailDraftsKey),
                  let drafts = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return drafts
        }
        set {
            let drafts = newValue.filter { !$0.value.isEmpty }
            guard !drafts.isEmpty else {
                UserDefaults.standard.removeObject(forKey: detailDraftsKey)
                return
            }
            guard let data = try? JSONEncoder().encode(drafts) else { return }
            UserDefaults.standard.set(data, forKey: detailDraftsKey)
        }
    }

    static func detailDraft(for workspaceID: String?) -> String {
        guard let workspaceID else { return "" }
        return detailDrafts[workspaceID] ?? ""
    }
}

private struct ToggleRequest: Encodable {
    var enabled: Bool
}

private struct WorkspaceToggleRequest: Encodable {
    var index: Int
    var enabled: Bool
}

private struct WorkspaceStarRequest: Encodable {
    var index: Int
    var starred: Bool
}

private struct RenameRequest: Encodable {
    var index: Int
    var name: String
}

private struct SendRequest: Encodable {
    var index: Int
    var text: String?
    var key: String?
    var surfaceId: String?
}

private struct NewSessionRequest: Encodable {
    var projectPath: String
    var branchName: String
    var jiraUrl: String
    var prompt: String
    var command: String
    var sessionName: String
}

private struct GitFileRequest: Encodable {
    var index: Int
    var file: String
}

private struct GitDiffRequest: Encodable {
    var index: Int
    var file: String
    var section: String
}

private struct PushDeviceRegistrationRequest: Encodable {
    var token: String
    var bundleId: String
    var environment: String
}

private struct PushApprovalClearRequest: Encodable {
    var workspaceID: String
    var workspaceUUID: String
    var surfaceID: String
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        self.encodeValue = { encoder in
            try value.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}
