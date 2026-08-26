import Foundation

struct ResponseAudioCapabilities: Decodable, Equatable, Sendable {
    let ok: Bool
    let available: Bool
    let listen: Bool
    let tldr: Bool

    static let unavailable = ResponseAudioCapabilities(
        ok: true,
        available: false,
        listen: false,
        tldr: false
    )

    func supports(_ action: ResponseAudioAction) -> Bool {
        switch action {
        case .listen: listen
        case .tldr: tldr
        }
    }
}
