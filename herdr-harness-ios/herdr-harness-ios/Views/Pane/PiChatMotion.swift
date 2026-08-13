import SwiftUI

enum PiChatMotion {
    static func structuralAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.26)
    }

    static func stateAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.18)
    }

    static func disclosureAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22)
    }

    static func turnTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: 10))
                .combined(with: .scale(scale: 0.985, anchor: .topLeading)),
            removal: .opacity
        )
    }

    static func itemTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: 7))
                .combined(with: .scale(scale: 0.99, anchor: .topLeading)),
            removal: .opacity
        )
    }

    static func stateTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.96))
    }

    static func jumpToLatestTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }
}
