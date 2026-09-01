import Foundation

actor HerdPulseRegistrationClient {
    private let configuration: ServerConfiguration
    private let session: URLSession

    init(configuration: ServerConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func register(
        activityID: String,
        pushToken: String,
        revealSessionTitles: Bool
    ) async throws -> HerdPulseAPNsCapability {
        let body = HerdPulseRegistrationBody(
            activityId: activityID,
            pushToken: pushToken,
            bundleId: Bundle.main.bundleIdentifier
                ?? "dev.ronnierocha.herdr-harness.herdr-harness-ios",
            environment: Self.apnsEnvironment,
            revealSessionTitles: revealSessionTitles
        )
        try await send(path: "/api/v1/live-activities", body: body)
        do {
            return try await fetchAPNsCapability()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The registration itself succeeded. Capability is supplemental
            // status and must not cause duplicate registration retries.
            return .unknown
        }
    }

    func unregister(activityID: String, pushToken: String?) async throws {
        let body = HerdPulseUnregistrationBody(activityId: activityID, pushToken: pushToken)
        try await send(path: "/api/v1/live-activities/unregister", body: body)
    }

    private func send<Body: Encodable & Sendable>(path: String, body: Body) async throws {
        var request = makeRequest(path: path, method: "POST")
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
    }

    private func fetchAPNsCapability() async throws -> HerdPulseAPNsCapability {
        let request = makeRequest(path: "/api/v1/push/status", method: "GET")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        let status = try JSONDecoder().decode(PushStatusResponse.self, from: data)
        return status.apns.configured ? .configured : .unavailable
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !configuration.token.isEmpty {
            request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(HerdPulseServerError.self, from: data))?.error.message ?? ""
            throw APIError.server(status: http.statusCode, message: message)
        }
    }

    private static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
}

private struct HerdPulseRegistrationBody: Encodable, Sendable {
    let activityId: String
    let pushToken: String
    let bundleId: String
    let environment: String
    let revealSessionTitles: Bool
}

private struct HerdPulseUnregistrationBody: Encodable, Sendable {
    let activityId: String
    let pushToken: String?
}

private struct HerdPulseServerError: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        let message: String
    }

    let error: Payload
}
