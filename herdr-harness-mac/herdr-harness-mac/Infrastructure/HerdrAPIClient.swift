import Foundation
import os

private let piStreamLog = OSLog(subsystem: "dev.ronnierocha.herdr-harness", category: "pi-stream")

actor HerdrAPIClient {
    private let configuration: ServerConfiguration
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(configuration: ServerConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func fetchWorkspaces() async throws -> WorkspacesResponse {
        try await request(path: "/api/v1/workspaces")
    }

    func fetchHealthProbe() async throws -> HealthProbeResponse {
        try await request(path: "/api/v1/health")
    }

    func fetchNetworkInfo() async throws -> NetworkInfoResponse {
        try await request(path: "/api/v1/network")
    }

    func fetchPaneOutput(paneID: String, lines: Int = 160) async throws -> PaneOutputResponse {
        try await request(
            path: "/api/v1/panes/\(paneID)/output",
            query: [
                URLQueryItem(name: "source", value: "recent_unwrapped"),
                URLQueryItem(name: "lines", value: String(lines)),
            ]
        )
    }

    func fetchGitStatus(workspaceID: String) async throws -> WorkspaceGitStatus {
        try await request(path: "/api/v1/workspaces/\(workspaceID)/git")
    }

    func startCleanupRun(_ request: CleanupStartRunRequest) async throws -> CleanupStartRunResponse {
        try await self.request(path: "/api/v1/cleanup/runs", method: "POST", body: request)
    }

    func fetchCleanupRun(id: String) async throws -> CleanupRunEnvelope {
        try await request(path: "/api/v1/cleanup/runs/\(id)")
    }

    func fetchCleanupRuns(limit: Int = 10) async throws -> CleanupRunListResponse {
        try await request(
            path: "/api/v1/cleanup/runs",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
    }

    func applyCleanupRun(
        id: String,
        paneIDs: [String],
        workspaceIDs: [String]
    ) async throws -> CleanupApplyResponse {
        try await request(
            path: "/api/v1/cleanup/runs/\(id)/apply",
            method: "POST",
            body: CleanupApplyRequest(paneIDs: paneIDs, workspaceIDs: workspaceIDs)
        )
    }

    func cancelCleanupRun(id: String) async throws {
        let _: MutationResponse = try await request(
            path: "/api/v1/cleanup/runs/\(id)/cancel",
            method: "POST",
            body: APIActionBody()
        )
    }

    func fetchCleanupModels() async throws -> CleanupModelCatalog {
        try await request(path: "/api/v1/cleanup/models")
    }

    func fetchGitDiff(
        workspaceID: String,
        file: String,
        section: GitFileSection
    ) async throws -> WorkspaceGitDiffResponse {
        try await request(
            path: "/api/v1/workspaces/\(workspaceID)/git/diff",
            query: [
                URLQueryItem(name: "file", value: file),
                URLQueryItem(name: "section", value: section.rawValue),
            ]
        )
    }

    func stageGitFile(workspaceID: String, file: String) async throws {
        let _: MutationResponse = try await request(
            path: "/api/v1/workspaces/\(workspaceID)/git/stage",
            method: "POST",
            body: WorkspaceGitFileBody(file: file)
        )
    }

    func unstageGitFile(workspaceID: String, file: String) async throws {
        let _: MutationResponse = try await request(
            path: "/api/v1/workspaces/\(workspaceID)/git/unstage",
            method: "POST",
            body: WorkspaceGitFileBody(file: file)
        )
    }

    func fetchSkills(workspaceID: String) async throws -> SkillsResponse {
        try await request(path: "/api/v1/workspaces/\(workspaceID)/skills")
    }

    func searchFiles(
        workspaceID: String,
        query: String,
        limit: Int = 80
    ) async throws -> FileSearchResponse {
        try await request(
            path: "/api/v1/workspaces/\(workspaceID)/files",
            query: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
    }

    func fetchAssignedJiraTickets(limit: Int = 50) async throws -> JiraTicketsResponse {
        try await request(
            path: "/api/v1/jira/assigned",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
    }

    func fetchJiraTicket(query: String) async throws -> JiraTicketResponse {
        try await request(
            path: "/api/v1/jira/issue",
            query: [URLQueryItem(name: "q", value: query)]
        )
    }

    func uploadAttachment(
        workspaceID: String,
        fileURL: URL,
        contentType: String
    ) async throws -> AttachmentUploadResponse {
        let candidate = try AttachmentPolicy.candidate(
            for: fileURL,
            ownership: .userSelected
        )
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { fileURL.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        try AttachmentPolicy.validateFile(
            named: candidate.filename,
            byteCount: Int64(data.count)
        )
        return try await request(
            path: "/api/v1/workspaces/\(workspaceID)/attachments",
            method: "POST",
            body: WorkspaceAttachmentBody(
                filename: fileURL.lastPathComponent,
                contentType: contentType,
                dataBase64: data.base64EncodedString()
            )
        )
    }

    func transcribeVoice(fileURL: URL) async throws -> VoiceTranscriptionResponse {
        let data = try VoiceRecordingPolicy.validatedData(at: fileURL)
        return try await request(
            path: "/api/v1/voice/transcriptions",
            method: "POST",
            body: VoiceTranscriptionRequest(
                filename: fileURL.lastPathComponent,
                mimeType: "audio/wav",
                dataBase64: data.base64EncodedString()
            )
        )
    }

    func createWorkspace(label: String, cwd: String) async throws {
        try await mutation(path: "/api/v1/workspaces", body: APIActionBody(label: label, cwd: cwd))
    }

    func renameWorkspace(id: String, label: String) async throws {
        try await mutation(
            path: "/api/v1/workspaces/\(id)",
            method: "PATCH",
            body: APIActionBody(label: label)
        )
    }

    func closeWorkspace(id: String) async throws {
        try await mutation(path: "/api/v1/workspaces/\(id)", method: "DELETE", body: APIActionBody())
    }

    func focusWorkspace(id: String) async throws {
        try await mutation(path: "/api/v1/workspaces/\(id)/focus", body: APIActionBody())
    }

    func createTab(workspaceID: String, label: String) async throws {
        try await mutation(path: "/api/v1/workspaces/\(workspaceID)/tabs", body: APIActionBody(label: label))
    }

    func createQuickPiSession(label: String) async throws -> QuickPiSessionResponse {
        try await request(
            path: "/api/v1/quick-sessions/pi",
            method: "POST",
            body: APIActionBody(label: label)
        )
    }

    func splitPane(id: String, direction: String) async throws {
        try await mutation(path: "/api/v1/panes/\(id)/split", body: APIActionBody(direction: direction, ratio: 0.5))
    }

    func renamePane(id: String, label: String) async throws {
        try await mutation(
            path: "/api/v1/panes/\(id)",
            method: "PATCH",
            body: APIActionBody(label: label)
        )
    }

    func focusPane(id: String) async throws {
        try await mutation(path: "/api/v1/panes/\(id)/focus", body: APIActionBody())
    }

    func setPaneStar(id: String, starred: Bool) async throws {
        let _: MutationResponse = try await request(
            path: "/api/v1/panes/\(id)/star",
            method: "POST",
            body: StarBody(starred: starred)
        )
    }

    func closePane(id: String) async throws {
        try await mutation(path: "/api/v1/panes/\(id)", method: "DELETE", body: APIActionBody())
    }

    func promptPane(id: String, text: String) async throws {
        try await mutation(path: "/api/v1/panes/\(id)/prompt", body: APIActionBody(text: text))
    }

    func sendText(toPane id: String, text: String, submit: Bool) async throws {
        if submit {
            try await runCommand(inPane: id, command: text)
        } else {
            try await mutation(path: "/api/v1/panes/\(id)/send-text", body: APIActionBody(text: text))
        }
    }

    func sendKeys(toPane id: String, keys: [String]) async throws {
        try await mutation(path: "/api/v1/panes/\(id)/send-keys", body: APIActionBody(keys: keys))
    }

    func runCommand(inPane id: String, command: String) async throws {
        try await mutation(path: "/api/v1/panes/\(id)/run", body: APIActionBody(command: command))
    }

    func startAgent(inPane id: String, name: String, kind: String) async throws {
        try await mutation(
            path: "/api/v1/panes/\(id)/start-agent",
            body: APIActionBody(kind: kind, name: name)
        )
    }

    func markAlertRead(id: String) async throws {
        try await mutation(path: "/api/v1/alerts/\(id)/read", body: APIActionBody())
    }

    func markAllAlertsRead() async throws {
        try await mutation(path: "/api/v1/alerts/read-all", body: APIActionBody())
    }

    func registerPushDevice(
        token: String,
        bundleID: String,
        environment: String
    ) async throws -> Bool {
        let body = PushDeviceBody(
            deviceToken: token,
            bundleId: bundleID,
            environment: environment
        )
        let _: MutationResponse = try await request(
            path: "/api/v1/push/devices",
            method: "POST",
            body: body
        )
        let status: PushStatusResponse = try await request(path: "/api/v1/push/status")
        return status.apns.configured
    }

    func events(after lastEventID: Int? = nil) -> AsyncThrowingStream<HerdrEvent, any Error> {
        var request = makeRequest(path: "/api/v1/events", method: "GET")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventID {
            request.setValue(String(lastEventID), forHTTPHeaderField: "Last-Event-ID")
        }
        let eventRequest = request
        let session = self.session

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: eventRequest)
                    try Self.validate(response: response)
                    var parser = HerdrSSEParser()

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let event = parser.consume(line: line) {
                            continuation.yield(event)
                        }
                    }
                    throw APIError.streamEnded
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func terminalEvents(
        paneID: String,
        columns: Int = 100,
        rows: Int = 32
    ) -> AsyncThrowingStream<TerminalStreamEvent, any Error> {
        var request = makeRequest(
            path: "/api/v1/panes/\(paneID)/stream",
            method: "GET",
            query: [
                URLQueryItem(name: "cols", value: String(columns)),
                URLQueryItem(name: "rows", value: String(rows)),
            ]
        )
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let terminalRequest = request
        let session = self.session

        // Terminal deltas are order-dependent. A bounded oldest-first buffer
        // therefore aborts on overflow, forcing a full-frame resync instead of
        // silently applying a corrupted suffix of the stream.
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: terminalRequest)
                    try Self.validate(response: response)
                    var parser = TerminalSSEParser()

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let event = try parser.consume(line: line) {
                            HerdrPerfDiagnostics.streamBacklog.noteYielded(.terminal)
                            if case .dropped = continuation.yield(event) {
                                HerdrPerfDiagnostics.streamBacklog.noteOverflow(.terminal)
                                continuation.finish(throwing: APIError.streamBacklogOverflow)
                                return
                            }
                        }
                    }
                    throw APIError.streamEnded
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func fetchPiConversationSnapshot(paneID: String) async throws -> PiConversationSnapshot {
        try await request(path: "/api/v1/panes/\(paneID)/pi/snapshot")
    }

    func fetchPiModels(paneID: String) async throws -> PiModelCatalogResponse {
        try await request(path: "/api/v1/panes/\(paneID)/pi/models")
    }

    func piConversationEvents(
        paneID: String,
        after cursor: String?
    ) -> AsyncThrowingStream<PiConversationStreamEvent, any Error> {
        let query = cursor.map { [URLQueryItem(name: "after", value: $0)] } ?? []
        var request = makeRequest(
            path: "/api/v1/panes/\(paneID)/pi/events",
            method: "GET",
            query: query
        )
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let cursor, !cursor.isEmpty {
            request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID")
        }
        let eventRequest = request
        let session = self.session

        // Pi envelopes are order-dependent. A bounded oldest-first buffer
        // resyncs from a snapshot on overflow rather than dropping a delta.
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: eventRequest)
                    try Self.validate(response: response)
                    var parser = PiConversationSSEParser()

                    for try await line in bytes.lines {
                        os_signpost(.event, log: piStreamLog, name: "sse.line")
                        try Task.checkCancellation()
                        if let event = try parser.consume(line: line) {
                            HerdrPerfDiagnostics.streamBacklog.noteYielded(.pi)
                            if case .dropped = continuation.yield(event) {
                                HerdrPerfDiagnostics.streamBacklog.noteOverflow(.pi)
                                continuation.finish(throwing: APIError.streamBacklogOverflow)
                                return
                            }
                        }
                    }
                    throw APIError.streamEnded
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func sendPiPrompt(
        paneID: String,
        text: String,
        disposition: PiPromptDisposition
    ) async throws {
        let path: String
        switch disposition {
        case .prompt:
            path = "/api/v1/panes/\(paneID)/pi/prompt"
        case .steer:
            path = "/api/v1/panes/\(paneID)/pi/steer"
        case .followUp:
            path = "/api/v1/panes/\(paneID)/pi/follow-up"
        }
        let response: PiCommandResponse = try await request(
            path: path,
            method: "POST",
            body: APIActionBody(text: text)
        )
        guard response.accepted else { throw APIError.invalidResponse }
    }

    func abortPiConversation(paneID: String) async throws {
        let response: PiCommandResponse = try await request(
            path: "/api/v1/panes/\(paneID)/pi/abort",
            method: "POST",
            body: APIActionBody()
        )
        guard response.accepted else { throw APIError.invalidResponse }
    }

    func setPiModel(paneID: String, provider: String, modelID: String) async throws {
        let response: PiCommandResponse = try await request(
            path: "/api/v1/panes/\(paneID)/pi/model",
            method: "POST",
            body: PiSetModelBody(provider: provider, id: modelID)
        )
        guard response.accepted else { throw APIError.invalidResponse }
    }

    func setPiThinkingLevel(paneID: String, level: String) async throws -> String? {
        let response: PiSetThinkingLevelResponse = try await request(
            path: "/api/v1/panes/\(paneID)/pi/thinking-level",
            method: "POST",
            body: PiSetThinkingLevelBody(level: level)
        )
        guard response.accepted else { throw APIError.invalidResponse }
        return response.level
    }

    func respondToPiInteraction(
        paneID: String,
        interactionID: String,
        response: PiInteractionResponseBody
    ) async throws {
        let safeInteractionID = interactionID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ) ?? interactionID
        let result: PiCommandResponse = try await request(
            path: "/api/v1/panes/\(paneID)/pi/interactions/\(safeInteractionID)/respond",
            method: "POST",
            body: response
        )
        guard result.accepted else { throw APIError.invalidResponse }
    }

    private func mutation(
        path: String,
        method: String = "POST",
        body: APIActionBody
    ) async throws {
        let _: MutationResponse = try await request(path: path, method: method, body: body)
    }

    private func request<Response: Decodable & Sendable>(
        path: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        let request = makeRequest(path: path, method: "GET", query: query)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func request<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        path: String,
        method: String,
        body: Body
    ) async throws -> Response {
        var request = makeRequest(path: path, method: method)
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func makeRequest(
        path: String,
        method: String,
        query: [URLQueryItem] = []
    ) -> URLRequest {
        var components = URLComponents(url: configuration.baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        var request = URLRequest(url: components?.url ?? configuration.baseURL)
        request.httpMethod = method
        request.timeoutInterval = Self.timeoutInterval(path: path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !configuration.token.isEmpty {
            request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func timeoutInterval(path: String, method: String) -> TimeInterval {
        if path == "/api/v1/health" || path == "/api/v1/network" {
            return 8
        }
        if path == "/api/v1/quick-sessions/pi" {
            return 75
        }
        if method != "GET", ["/send-text", "/send-keys", "/run"].contains(where: path.hasSuffix) {
            return 5
        }
        if method == "GET" && (path.hasSuffix("events") || path.hasSuffix("stream")) {
            return 24 * 60 * 60
        }
        if path.hasSuffix("/attachments") {
            // The original cmux upload contract allows a full minute. Leave
            // headroom for the authenticated Herdr proxy hop as well.
            return 90
        }
        if path == "/api/v1/voice/transcriptions" {
            return 120
        }
        if path.hasPrefix("/api/v1/jira/") ||
            (path.hasPrefix("/api/v1/workspaces/") &&
                (path.contains("/git") || path.hasSuffix("/skills") || path.hasSuffix("/files"))) {
            // cmux permits Git and Jira operations to run for up to 10 and 15
            // seconds respectively. The client must outlive the upstream call.
            return 30
        }
        return 15
    }

    private static func validate(response: URLResponse, data: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data).error.message) ?? ""
            throw APIError.server(status: http.statusCode, message: message)
        }
    }
}

struct TerminalSSEParser {
    private var eventName = "message"
    private var dataLines: [String] = []
    private let decoder = JSONDecoder()

    mutating func consume(line: String) throws -> TerminalStreamEvent? {
        if line.hasPrefix(":") {
            return .activity
        }
        if line.hasPrefix("event:") {
            if !dataLines.isEmpty { resetRecord() }
            eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            try enforceBufferLimit()
            return try dispatchIfComplete(force: false)
        }
        guard line.isEmpty else { return nil }
        return try dispatchIfComplete(force: true)
    }

    private mutating func dispatchIfComplete(force: Bool) throws -> TerminalStreamEvent? {
        guard !dataLines.isEmpty else {
            if force { resetRecord() }
            return nil
        }

        switch eventName {
        case "ready":
            resetRecord()
            return .ready
        case "heartbeat":
            resetRecord()
            return .activity
        case "terminal.frame":
            let payload = dataLines.joined(separator: "\n")
            guard let data = payload.data(using: .utf8) else {
                if force { resetRecord(); throw APIError.invalidResponse }
                return nil
            }
            guard let frame = try? decoder.decode(TerminalFrame.self, from: data) else {
                if force { resetRecord(); throw APIError.invalidResponse }
                return nil
            }
            resetRecord()
            return .frame(frame)
        case "terminal.error", "terminal.closed":
            resetRecord()
            throw APIError.streamEnded
        default:
            if force { resetRecord() }
            return nil
        }
    }

    private mutating func resetRecord() {
        eventName = "message"
        dataLines.removeAll(keepingCapacity: true)
    }

    private mutating func enforceBufferLimit() throws {
        guard dataLines.count <= 64,
              dataLines.reduce(0, { $0 + $1.lengthOfBytes(using: .utf8) + 1 }) <= 4 * 1024 * 1024
        else {
            resetRecord()
            throw APIError.invalidResponse
        }
    }
}

/// Parses Herdr's SSE records, which are either broker envelopes containing an
/// inner event payload or hand-written records whose JSON payload is the event data.
struct HerdrSSEParser {
    static let decodedEventNames: Set<String> = [
        "snapshot.updated", "alert.created", "alert.updated", "alerts.read_state_changed",
        "stars.changed", "push.delivery", "ready", "stream.reset", "cleanup.run_updated",
        "pi.bridge.connection", "pi.session_start", "pi.session_shutdown", "pi.session_info_changed",
        "pi.session_tree", "pi.session_compact",
    ]

    private var eventName = "message"
    private var eventID: Int?
    private var dataLines: [String] = []
    private let decoder = JSONDecoder()

    mutating func consume(line: String) -> HerdrEvent? {
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            if !dataLines.isEmpty { resetRecord() }
            eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("id:") {
            if !dataLines.isEmpty { resetRecord() }
            eventID = Int(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            return nil
        }
        if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            if dataLines.count > 64 || dataLines.reduce(0, { $0 + $1.lengthOfBytes(using: .utf8) + 1 }) > 4 * 1024 * 1024 {
                resetRecord()
                return nil
            }
            return dispatchIfComplete(force: false)
        }
        guard line.isEmpty else { return nil }
        return dispatchIfComplete(force: true)
    }

    private mutating func dispatchIfComplete(force: Bool) -> HerdrEvent? {
        guard !dataLines.isEmpty else {
            if force { resetRecord() }
            return nil
        }

        let name = eventName
        let id = eventID
        if name != "message", !Self.decodedEventNames.contains(name) {
            resetRecord()
            return HerdrEvent(id: id, event: name, data: .null)
        }
        guard let data = dataLines.joined(separator: "\n").data(using: .utf8) else {
            if force { resetRecord() }
            return nil
        }
        if let value = try? decoder.decode(JSONValue.self, from: data) {
            let event: HerdrEvent
            if case let .object(object) = value,
               let innerData = object["data"],
               case let .string(innerName)? = object["event"] {
                let innerID: Int?
                if case let .number(number)? = object["id"] {
                    innerID = Int(number)
                } else {
                    innerID = nil
                }
                event = HerdrEvent(id: innerID ?? id, event: innerName, data: innerData)
            } else {
                let messageName: String?
                if case let .object(object) = value,
                   case let .string(innerName)? = object["event"] {
                    messageName = innerName
                } else {
                    messageName = nil
                }
                event = HerdrEvent(id: id, event: name == "message" ? (messageName ?? "message") : name, data: value)
            }
            resetRecord()
            return event
        }
        if force { resetRecord() }
        return nil
    }

    private mutating func resetRecord() {
        eventName = "message"
        eventID = nil
        dataLines.removeAll(keepingCapacity: true)
    }
}

private struct ServerErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let code: String
        let message: String
    }

    let error: Payload
}

private struct StarBody: Encodable, Sendable {
    let starred: Bool
}
