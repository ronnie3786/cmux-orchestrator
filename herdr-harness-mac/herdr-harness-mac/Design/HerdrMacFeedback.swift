import AppKit

/// The Mac sink for Herdr's semantic feedback vocabulary.
///
/// `SensoryFeedback` still drives the taptic channel (Force Touch trackpads),
/// but a Mac window is usually *not* the thing in your hand, so the two events
/// that carry news — an agent needing you (`.attention`) and an agent finishing
/// (`.completed`) — also get a quiet system sound.
///
/// Everything else stays silent on purpose. Key presses, toggles, staging and
/// recording lifecycle are direct manipulation: the user already knows they did
/// it. `play(_:)` is the only place in the app that makes noise — route any
/// future mute setting through `isEnabled` rather than adding a second caller.
@MainActor
enum HerdrMacFeedback {
    /// Master mute. Reserved for a future Settings toggle.
    static var isEnabled = true

    /// The single funnel. Non-newsworthy events return without touching AppKit.
    static func play(_ event: HerdrHaptic) {
        guard isEnabled, let cue = Cue(event), let sound = sound(for: cue) else { return }

        // Restart rather than overlap: a burst of transitions should read as one
        // notification, not a pile of them.
        if sound.isPlaying {
            sound.stop()
        }
        sound.volume = cue.volume
        sound.play()
    }

    /// The closed set of events that are allowed to be audible.
    private enum Cue {
        case attention
        case completed

        init?(_ event: HerdrHaptic) {
            switch event {
            case .attention:
                self = .attention
            case .completed:
                self = .completed
            default:
                return nil
            }
        }

        var name: NSSound.Name {
            switch self {
            case .attention:
                "Funk"
            case .completed:
                "Glass"
            }
        }

        /// `.completed` is deliberately quieter — good news can afford to be soft.
        var volume: Float {
            switch self {
            case .attention:
                0.6
            case .completed:
                0.35
            }
        }
    }

    private static var sounds: [NSSound.Name: NSSound] = [:]

    private static func sound(for cue: Cue) -> NSSound? {
        if let cached = sounds[cue.name] {
            return cached
        }

        guard let sound = NSSound(named: cue.name) else { return nil }
        sounds[cue.name] = sound
        return sound
    }
}
