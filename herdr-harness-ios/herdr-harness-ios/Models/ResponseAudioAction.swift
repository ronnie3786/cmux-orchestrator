import Foundation

enum ResponseAudioAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case listen
    case tldr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .listen: "Listen"
        case .tldr: "TL;DR"
        }
    }

    var systemImage: String {
        switch self {
        case .listen: "speaker.wave.2.fill"
        case .tldr: "text.quote"
        }
    }
}
