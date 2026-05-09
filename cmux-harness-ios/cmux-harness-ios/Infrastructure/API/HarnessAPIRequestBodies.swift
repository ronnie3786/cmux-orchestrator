import Foundation

struct ToggleRequest: Encodable {
    var enabled: Bool
}

struct WorkspaceToggleRequest: Encodable {
    var index: Int
    var enabled: Bool
    var autoMode: String
}

struct WorkspaceStarRequest: Encodable {
    var index: Int
    var starred: Bool
}

struct RenameRequest: Encodable {
    var index: Int
    var name: String
}

struct SendRequest: Encodable {
    var index: Int
    var text: String?
    var key: String?
    var surfaceId: String?
}

struct NewSessionRequest: Encodable {
    var projectPath: String
    var branchName: String
    var jiraUrl: String
    var prompt: String
    var command: String
    var sessionName: String
}

struct GitFileRequest: Encodable {
    var index: Int
    var file: String
}

struct GitDiffRequest: Encodable {
    var index: Int
    var file: String
    var section: String
}

struct PushDeviceRegistrationRequest: Encodable {
    var token: String
    var bundleId: String
    var environment: String
}

struct PushApprovalClearRequest: Encodable {
    var workspaceID: String
    var workspaceUUID: String
    var surfaceID: String
}

struct FeedReplyRequest: Encodable {
    var requestID: String
    var kind: String
    var action: String?
    var mode: String?
    var selections: [String]?
}

struct AnyEncodable: Encodable {
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
