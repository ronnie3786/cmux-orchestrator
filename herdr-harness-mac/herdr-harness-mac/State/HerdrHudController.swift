import AppKit
import Carbon.HIToolbox
import Observation
import QuartzCore
import SwiftUI

/// Lets the transparent parts of the HUD panel pass clicks through.
///
/// The panel is borderless and fully transparent, but AppKit hit-tests an
/// `NSHostingView` geometrically, so without this the whole frame — including
/// the empty space around the orb and between the session chips — swallows
/// clicks meant for whatever is underneath. Returning `nil` for a hit that
/// lands on the hosting view itself, rather than on one of SwiftUI's own
/// hit-testable subviews, keeps the controls live and gives the rest back.
final class HerdrHudHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

final class HerdrHudPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
@Observable
final class HerdrHudController {
    private enum DefaultsKey {
        static let enabled = "herdr.hud.enabled"
        static let offset = "herdr.hud.offset.v2"
    }

    private let userDefaults: UserDefaults
    private var panel: HerdrHudPanel?
    private var hotKey: HerdrGlobalHotKey?
    private var session: HerdrHudSession?
    private var placementOffset = HerdrHudPlacement.defaultOffset()
    private var notificationTokens: [NSObjectProtocol] = []
    private var isConfigured = false
    private var isProgrammaticMove = false
    private var enabledRevision = 0

    private(set) var isExpanded = false
    private(set) var focusRequest = 0
    private(set) var collapsedChipCount = 0

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var isEnabled: Bool {
        _ = enabledRevision
        guard userDefaults.object(forKey: DefaultsKey.enabled) != nil else { return true }
        return userDefaults.bool(forKey: DefaultsKey.enabled)
    }

    func configure(
        model: HerdrAppModel,
        session: HerdrHudSession,
        fontScale: HerdrFontScaleStore
    ) {
        guard !isConfigured else { return }
        isConfigured = true
        self.session = session
        placementOffset = loadPlacementOffset()

        let initialFrame = frame(for: false)
        let panel = HerdrHudPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.onCancel = { [weak self] in self?.collapse() }
        panel.contentView = HerdrHudHostingView(
            rootView: HerdrHudRootView(
                model: model,
                controller: self,
                session: session,
                fontScale: fontScale
            )
        )
        self.panel = panel
        // The root view reports its initial chip count while the hosting view
        // is being installed. Reapply after retaining the panel so an eager
        // initial report cannot be lost before `self.panel` was available.
        applyFrame(animated: false)
        installObservers(for: panel)
        session.isCollapsed = true

        if isEnabled {
            installHotKey()
            panel.orderFrontRegardless()
        }
    }

    func summon() {
        if !isEnabled {
            setEnabled(true)
        }
        guard let panel else { return }
        isExpanded = true
        session?.isCollapsed = false
        applyFrame(animated: true)
        panel.makeKeyAndOrderFront(nil)
        focusRequest &+= 1
        session?.markSeen()
    }

    func collapse() {
        guard let panel else { return }
        isExpanded = false
        session?.isCollapsed = true
        applyFrame(animated: true)
        if panel.isKeyWindow {
            panel.orderOut(nil)
        }
        panel.orderFrontRegardless()
    }

    func toggleFromHotKey() {
        guard let panel else { return }
        if !panel.isVisible || !isExpanded {
            summon()
        } else {
            collapse()
        }
    }

    func setEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: DefaultsKey.enabled)
        enabledRevision &+= 1
        guard let panel else { return }

        if enabled {
            installHotKey()
            isExpanded = false
            session?.isCollapsed = true
            applyFrame(animated: false)
            panel.orderFrontRegardless()
        } else {
            isExpanded = false
            session?.isCollapsed = true
            applyFrame(animated: false)
            panel.orderOut(nil)
            hotKey?.unregister()
        }
    }

    func setCollapsedChipCount(_ count: Int) {
        let clampedCount = min(max(0, count), HerdrHudPlacement.maxChips)
        guard collapsedChipCount != clampedCount else { return }
        collapsedChipCount = clampedCount
        if !isExpanded {
            applyFrame(animated: true)
        }
    }

    private func installHotKey() {
        if hotKey == nil {
            hotKey = HerdrGlobalHotKey(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(controlKey | optionKey)
            ) { [weak self] in
                self?.toggleFromHotKey()
            }
        }
        _ = hotKey?.register()
    }

    private func installObservers(for panel: HerdrHudPanel) {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.persistCurrentPlacement() }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reclampPlacement() }
            }
        )
    }

    private func persistCurrentPlacement() {
        guard !isProgrammaticMove else { return }
        guard let panel else { return }
        placementOffset = HerdrHudPlacement.offset(
            forFrame: panel.frame,
            visibleFrame: visibleFrame(for: panel)
        )
        savePlacementOffset()
    }

    private func reclampPlacement() {
        guard let panel else { return }
        isProgrammaticMove = true
        panel.setFrame(frame(for: isExpanded), display: true)
        DispatchQueue.main.async { [weak self] in
            self?.isProgrammaticMove = false
        }
    }

    private func applyFrame(animated: Bool) {
        guard let panel else { return }
        let newFrame = frame(for: isExpanded)
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        isProgrammaticMove = true
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }, completionHandler: { [weak self] in
                DispatchQueue.main.async {
                    self?.isProgrammaticMove = false
                }
            })
        } else {
            panel.setFrame(newFrame, display: true)
            DispatchQueue.main.async { [weak self] in
                self?.isProgrammaticMove = false
            }
        }
    }

    private func frame(for isExpanded: Bool) -> CGRect {
        HerdrHudPlacement.frame(
            isExpanded: isExpanded,
            visibleFrame: visibleFrame(for: panel),
            topRightOffset: placementOffset,
            chipCount: isExpanded ? 0 : collapsedChipCount
        )
    }

    private func visibleFrame(for panel: NSPanel?) -> CGRect {
        panel?.screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
    }

    private func loadPlacementOffset() -> CGSize {
        guard let values = userDefaults.array(forKey: DefaultsKey.offset) as? [NSNumber], values.count == 2 else {
            return HerdrHudPlacement.defaultOffset()
        }
        return CGSize(width: values[0].doubleValue, height: values[1].doubleValue)
    }

    private func savePlacementOffset() {
        userDefaults.set([placementOffset.width, placementOffset.height], forKey: DefaultsKey.offset)
    }
}
