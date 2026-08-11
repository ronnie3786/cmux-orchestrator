import Foundation

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

    func fetchPaneOutput(paneID: String, lines: Int = 160) async throws -> PaneOutputResponse {
        try await request(
            path: "/api/v1/panes/\(paneID)/output",
            query: [
                URLQueryItem(name: "source", value: "recent_unwrapped"),
                URLQueryItem(name: "lines", value: String(lines)),
            ]
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

    func events() -> AsyncThrowingStream<HerdrEvent, any Error> {
        var request = makeRequest(path: "/api/v1/events", method: "GET")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let eventRequest = request
        let session = self.session
        let decoder = self.decoder

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: eventRequest)
                    try Self.validate(response: response)

                    var eventName = "message"
                    var dataLines: [String] = []

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                let payload = dataLines.joined(separator: "\n")
                                if let data = payload.data(using: .utf8) {
                                    if let event = try? decoder.decode(HerdrEvent.self, from: data) {
                                        continuation.yield(event)
                                    } else if let value = try? decoder.decode(JSONValue.self, from: data) {
                                        continuation.yield(HerdrEvent(event: eventName, data: value))
                                    }
                                }
                            }
                            eventName = "message"
                            dataLines.removeAll(keepingCapacity: true)
                        } else if line.hasPrefix("event:") {
                            eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
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

    func terminalFrames(
        paneID: String,
        columns: Int = 100,
        rows: Int = 32
    ) -> AsyncThrowingStream<TerminalFrame, any Error> {
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
        let decoder = self.decoder

        // Terminal delta frames are order-dependent, so do not drop intermediate
        // values. The consumer applies them synchronously to a bounded grid.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: terminalRequest)
                    try Self.validate(response: response)
                    var eventName = "message"
                    var dataLines: [String] = []

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.isEmpty {
                            if eventName == "terminal.frame", !dataLines.isEmpty {
                                let payload = dataLines.joined(separator: "\n")
                                guard let data = payload.data(using: .utf8),
                                      let frame = try? decoder.decode(TerminalFrame.self, from: data)
                                else { throw APIError.invalidResponse }
                                continuation.yield(frame)
                            } else if eventName == "terminal.error" || eventName == "terminal.closed" {
                                throw APIError.streamEnded
                            }
                            eventName = "message"
                            dataLines.removeAll(keepingCapacity: true)
                        } else if line.hasPrefix("event:") {
                            eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
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
        request.timeoutInterval = method == "GET" && path.hasSuffix("events") ? 24 * 60 * 60 : 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !configuration.token.isEmpty {
            request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func validate(response: URLResponse, data: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data).error.message) ?? ""
            throw APIError.server(status: http.statusCode, message: message)
        }
    }
}

private struct ServerErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let code: String
        let message: String
    }

    let error: Payload
}
