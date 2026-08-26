import Foundation

struct ResponseAudioSpeechResponse: Decodable, Sendable {
    let ok: Bool
    let audioBase64: String
    let contentType: String
}
