import Observation
import Foundation

/// Voice capture shares the HUD panel, so the orb, microphone and progress
/// notifications always move and hide together.
@MainActor
@Observable
final class QuickVoicePanelController {
    let session: QuickVoiceSession
    private(set) var isExpanded = false
    private(set) var isEnabled: Bool
    @ObservationIgnored private weak var hud: HerdrHudController?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        session = QuickVoiceSession(defaults: defaults)
        isEnabled = defaults.object(forKey: "herdr.quickVoice.enabled") == nil || defaults.bool(forKey: "herdr.quickVoice.enabled")
    }

    func configure(model: HerdrAppModel, hud: HerdrHudController) {
        self.hud = hud
        session.configure(model: model)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: "herdr.quickVoice.enabled")
        if !enabled { collapse() }
    }

    func capture() {
        if !isEnabled { setEnabled(true) }
        isExpanded = true
        hud?.presentQuickVoice()
        session.toggleCapture()
    }

    func showDetails(noteID: String? = nil) {
        if let noteID { session.selectNote(noteID) }
        else if session.selectedNote == nil, let latest = session.notes.first { session.selectNote(latest.id) }
        isExpanded = true
        hud?.presentQuickVoice()
    }

    func collapse() {
        session.cancelRecording()
        isExpanded = false
        hud?.quickVoiceLayoutDidChange()
    }
}
