import SwiftUI

/// The small, semantic haptic vocabulary used throughout Herdr.
///
/// Keep this list tied to user intent. Live terminal frames and polling updates
/// must never emit feedback.
enum HerdrHaptic: Equatable, Sendable {
    case selection
    case terminalKey
    case controlsExpanded
    case controlsCollapsed
    case promptSent
    case gitStaged
    case gitUnstaged
    case recordingStarted
    case recordingStopped
    case transcriptionStarted
    case transcriptionSucceeded
    case attention
    case stopped
    case completed
    case failed

    var feedback: SensoryFeedback {
        switch self {
        case .selection:
            .selection
        case .terminalKey:
            .press(.buttonIconOnly)
        case .controlsExpanded:
            .selection(.on)
        case .controlsCollapsed:
            .selection(.off)
        case .promptSent, .transcriptionSucceeded, .completed:
            .success
        case .gitStaged:
            .increase
        case .gitUnstaged:
            .decrease
        case .recordingStarted, .transcriptionStarted:
            .start
        case .recordingStopped, .stopped:
            .stop
        case .attention:
            .warning
        case .failed:
            .error
        }
    }
}
