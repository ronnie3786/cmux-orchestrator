import Foundation

enum APIError: LocalizedError, Sendable {
    case invalidResponse
    case noActiveConnection(machineID: String)
    case server(status: Int, message: String)
    case cleanupApplyStatusUnknown(message: String)
    case streamEnded
    case streamBacklogOverflow

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The Herdr server returned an invalid response."
        case let .noActiveConnection(machineID): "Machine \(machineID) has no active connection."
        case let .server(status, message): message.isEmpty ? "Herdr server error (\(status))." : message
        case let .cleanupApplyStatusUnknown(message): message
        case .streamEnded: "The live Herdr connection ended."
        case .streamBacklogOverflow: "Herdr fell behind the live stream and is resyncing."
        }
    }
}
