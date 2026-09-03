import Foundation

/// A user-facing result deliberately presented by an agent.
///
/// Result IDs originate on a Herdr server, so they are only unique within a
/// machine. `stamped(machineID:)` gives every presentation a stable fleet-wide
/// identity before it enters app state.
struct AgentResultArtifact: Decodable, Equatable, Hashable, Identifiable, Sendable {
    /// A compromised or misconfigured remote machine must never be able to
    /// turn one user click into an unbounded Mac download. This matches the
    /// harness's default per-artifact ceiling and remains independent of its
    /// remotely configurable limits.
    static let maximumDownloadByteSize: Int64 = 512 * 1_024 * 1_024

    enum OriginType: String, Codable, Sendable {
        case pane
        case agentRun = "agent_run"
    }

    enum Kind: String, Codable, Sendable {
        case file
        case link
    }

    let rawID: String
    let originType: OriginType
    let originID: String
    let sessionID: String?
    let kind: Kind
    let title: String
    let filename: String?
    let contentType: String?
    let byteSize: Int64?
    let createdAt: String
    let downloadPath: String?
    let url: URL?

    private(set) var machineID = ""

    var id: String {
        machineID.isEmpty ? rawID : MachineScopedID.compose(machineID: machineID, rawID: rawID)
    }

    var displayTitle: String {
        for candidate in [title, filename, url?.host] {
            if let candidate,
               !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return "Agent result"
    }

    var createdDate: Date? {
        HerdrTimestamp.date(from: createdAt)
    }

    func stamped(machineID: String) -> AgentResultArtifact {
        var copy = self
        copy.machineID = machineID
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case id
        case originType
        case originID = "originId"
        case sessionID = "sessionId"
        case kind
        case title
        case filename
        case contentType
        case byteSize
        case createdAt
        case downloadPath
        case url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        let originType = try container.decode(OriginType.self, forKey: .originType)
        let originID = try container.decode(String.self, forKey: .originID)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let filename = try container.decodeIfPresent(String.self, forKey: .filename)
        let contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
        let byteSize = try container.decodeIfPresent(Int64.self, forKey: .byteSize)
        let downloadPath = try container.decodeIfPresent(String.self, forKey: .downloadPath)
        let url = try container.decodeIfPresent(URL.self, forKey: .url)

        try Self.validate(
            rawID: rawID,
            originID: originID,
            kind: kind,
            filename: filename,
            byteSize: byteSize,
            downloadPath: downloadPath,
            url: url,
            codingPath: decoder.codingPath
        )

        self.rawID = rawID
        self.originType = originType
        self.originID = originID
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        self.kind = kind
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.filename = filename
        self.contentType = contentType
        self.byteSize = byteSize
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        self.downloadPath = downloadPath
        self.url = url
    }

    init(
        id: String,
        originType: OriginType,
        originID: String,
        sessionID: String? = nil,
        kind: Kind,
        title: String,
        filename: String? = nil,
        contentType: String? = nil,
        byteSize: Int64? = nil,
        createdAt: String,
        downloadPath: String? = nil,
        url: URL? = nil
    ) {
        rawID = id
        self.originType = originType
        self.originID = originID
        self.sessionID = sessionID
        self.kind = kind
        self.title = title
        self.filename = filename
        self.contentType = contentType
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.downloadPath = downloadPath
        self.url = url
    }

    /// Decodes the lightweight JSON representation used by the fleet SSE
    /// stream without making `JSONValue` globally encodable.
    init?(eventData: JSONValue?) {
        guard case let .object(root)? = eventData else { return nil }
        let values: [String: JSONValue]
        if case let .object(artifact)? = root["artifact"] {
            values = artifact
        } else {
            values = root
        }

        func string(_ key: String) -> String? {
            guard case let .string(value)? = values[key] else { return nil }
            return value
        }
        func integer(_ key: String) -> Int64? {
            guard case let .number(value)? = values[key], value.isFinite,
                  value.rounded(.towardZero) == value,
                  value >= Double(Int64.min), value <= Double(Int64.max)
            else { return nil }
            return Int64(value)
        }

        guard let rawID = string("id"),
              let originRaw = string("originType"),
              let originType = OriginType(rawValue: originRaw),
              let originID = string("originId"),
              let kindRaw = string("kind"),
              let kind = Kind(rawValue: kindRaw)
        else { return nil }

        let filename = string("filename")
        let byteSize = integer("byteSize")
        let downloadPath = string("downloadPath")
        let url = string("url").flatMap(URL.init(string:))
        guard (try? Self.validate(
            rawID: rawID,
            originID: originID,
            kind: kind,
            filename: filename,
            byteSize: byteSize,
            downloadPath: downloadPath,
            url: url,
            codingPath: []
        )) != nil else { return nil }

        self.rawID = rawID
        self.originType = originType
        self.originID = originID
        sessionID = string("sessionId")
        self.kind = kind
        title = string("title") ?? ""
        self.filename = filename
        contentType = string("contentType")
        self.byteSize = byteSize
        createdAt = string("createdAt") ?? ""
        self.downloadPath = downloadPath
        self.url = url
    }

    private static func validate(
        rawID: String,
        originID: String,
        kind: Kind,
        filename: String?,
        byteSize: Int64?,
        downloadPath: String?,
        url: URL?,
        codingPath: [any CodingKey]
    ) throws {
        guard !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !originID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              byteSize.map({ $0 >= 0 }) ?? true
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: codingPath, debugDescription: "Result artifact metadata is incomplete")
            )
        }

        switch kind {
        case .file:
            guard filename?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  downloadPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  let byteSize,
                  byteSize <= maximumDownloadByteSize,
                  url == nil
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: codingPath, debugDescription: "File result metadata is incomplete")
                )
            }
        case .link:
            guard filename == nil, downloadPath == nil,
                  let url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: codingPath, debugDescription: "Link result URL is not openable")
                )
            }
        }
    }
}

struct ResultArtifactsResponse: Decodable, Sendable {
    let ok: Bool
    let artifacts: [AgentResultArtifact]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)

        // A remote harness may support a broader artifact contract than this
        // Mac build, such as a file above the local download ceiling. Advance
        // one element at a time so an unsupported or malformed result cannot
        // hide every otherwise safe result from that machine. The envelope and
        // the `artifacts` field itself remain strict JSON contracts.
        var values = try container.nestedUnkeyedContainer(forKey: .artifacts)
        var supported: [AgentResultArtifact] = []
        while !values.isAtEnd {
            let valueDecoder = try values.superDecoder()
            if let artifact = try? AgentResultArtifact(from: valueDecoder) {
                supported.append(artifact)
            }
        }
        artifacts = supported
    }

    private enum CodingKeys: String, CodingKey {
        case ok, artifacts
    }
}

enum AgentResultArtifactPhase: Equatable, Sendable {
    case available
    case opening
    case downloading
    case opened
    case failed(String)
}
