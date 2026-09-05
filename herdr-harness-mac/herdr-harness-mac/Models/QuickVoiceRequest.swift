import Foundation

struct QuickVoiceRequest: Codable, Sendable {
    let requestId: String
    let text: String
    let cwd: String?
}
