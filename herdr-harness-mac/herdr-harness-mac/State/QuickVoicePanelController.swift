import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class QuickVoicePanelController {
    let session = QuickVoiceSession()
    private(set) var isExpanded = false
    private(set) var isEnabled: Bool
    @ObservationIgnored private var panel: HerdrHudPanel?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var screenObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: "herdr.quickVoice.enabled") == nil || defaults.bool(forKey: "herdr.quickVoice.enabled")
    }

    func configure(model: HerdrAppModel, fontScale: HerdrFontScaleStore) {
        guard panel == nil else { return }
        session.configure(model: model)
        let panel = HerdrHudPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.collapse() }
        self.panel = panel
        panel.contentView = NSHostingView(rootView: QuickVoicePanelView(controller: self, session: session, model: model, fontScale: fontScale))
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
        let savedX = defaults.object(forKey: "herdr.quickVoice.x") as? Double
        let savedY = defaults.object(forKey: "herdr.quickVoice.y") as? Double
        panel.setFrame(CGRect(x: savedX ?? screen.maxX - 150, y: savedY ?? screen.minY + 70, width: 130, height: 76), display: false)
        resize()
        if isEnabled { panel.orderFrontRegardless() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resize() }
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: "herdr.quickVoice.enabled")
        if enabled { panel?.orderFrontRegardless() }
        else {
            session.cancelRecording()
            panel?.orderOut(nil)
        }
    }

    func capture() {
        if !isEnabled { setEnabled(true) }
        isExpanded = true
        resize()
        panel?.makeKeyAndOrderFront(nil)
        session.toggleCapture()
    }

    func toggleDetails() {
        isExpanded.toggle()
        resize()
        if isExpanded { panel?.makeKeyAndOrderFront(nil) }
        else { panel?.orderFrontRegardless() }
    }

    func collapse() {
        session.cancelRecording()
        isExpanded = false
        resize()
        panel?.orderFrontRegardless()
    }

    func savePosition() {
        resize()
        guard let panel else { return }
        defaults.set(panel.frame.minX, forKey: "herdr.quickVoice.x")
        defaults.set(panel.frame.minY, forKey: "herdr.quickVoice.y")
    }

    private func resize() {
        guard let panel else { return }
        let size = isExpanded ? CGSize(width: 380, height: 500) : CGSize(width: 130, height: 76)
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(panel.frame) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
        let x = min(max(panel.frame.maxX - size.width, screen.minX), screen.maxX - size.width)
        let y = min(max(panel.frame.minY, screen.minY), screen.maxY - size.height)
        panel.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true)
    }
}
