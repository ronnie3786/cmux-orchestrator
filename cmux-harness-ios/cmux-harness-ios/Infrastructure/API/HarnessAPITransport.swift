import Foundation
import UniformTypeIdentifiers

extension HarnessAPI {
    static func request<T: Decodable>(
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
            if let prComments = decoded as? GitHubPRCommentsResponse, !prComments.ok {
                throw HarnessAPIError.server(prComments.error ?? "GitHub PR comments request failed")
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
            if let jiraTicket = decoded as? JiraTicketResponse, !jiraTicket.ok {
                throw HarnessAPIError.server(jiraTicket.error ?? "Jira ticket request failed")
            }
            return decoded
        } catch let error as HarnessAPIError {
            throw error
        } catch {
            throw HarnessAPIError.transport(error.localizedDescription)
        }
    }

    static func uploadWithTimeout(request: URLRequest, fileURL: URL) async throws -> (Data, URLResponse) {
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

    static func fileByteCount(_ url: URL) throws -> Int64 {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return Int64(size)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber {
            return size.int64Value
        }
        return 0
    }

    static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              let mimeType = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mimeType
    }

    static func percentEncodedHeaderValue(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment"
    }

    nonisolated static func makeURL(
        baseURLString: String,
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        let normalized = normalizedBaseURL(baseURLString)
        guard !normalized.isEmpty else {
            throw HarnessAPIError.invalidURL
        }
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

    nonisolated static func apiBasePath(from path: String) -> String {
        var basePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath == "harness" {
            basePath = ""
        } else if basePath.hasSuffix("/harness") {
            basePath.removeLast("/harness".count)
        }
        return basePath
    }
}
