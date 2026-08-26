import Foundation

enum ResponseAudioPlaybackPhase: Equatable, Sendable {
    case unavailable
    case checking
    case idle
    case preparing(ResponseAudioAction)
    case playing(ResponseAudioAction)
    case paused(ResponseAudioAction)

    var activeAction: ResponseAudioAction? {
        switch self {
        case let .preparing(action), let .playing(action), let .paused(action): action
        case .unavailable, .checking, .idle: nil
        }
    }
}
