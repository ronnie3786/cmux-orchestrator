import Foundation

struct ResponseAudioPrepareResponse: Decodable, Sendable {
    let ok: Bool
    let action: ResponseAudioAction
    let chunks: [String]
}
