import AppKit
import Carbon.HIToolbox
import Observation
import QuartzCore
import SwiftUI

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
    private var notes: HerdrHudNotesState?
    private var lastNotesLayout: HerdrHudPlacement.NotesLayout = .hidden
    private var placementOffset = HerdrHudPlacement.defaultOffset()
    private var notificationTokens: [NSObjectProtocol] = []
    private var isConfigured = false
    private var isProgrammaticMove = false
    /// Hover-driven notes layouts can start a new frame animation while the
    /// previous one is still running. Only the newest animation's completion
    /// may clear `isProgrammaticMove`, or an intermediate frame gets persisted
    /// as the user's chosen placement.
    private var frameAnimationGeneration = 0
    private var enabledRevision = 0

    private(set) var isExpanded = false
    private(set) var focusRequest = 0
    private(set) var noteFocusRequest = 0
    private(set) var collapsedChipCount = 0
    /// Whether the `+N` control has been clicked to reveal the grouped
    /// sessions. Regrouped `chipRegroupDelay` after the pointer leaves them.
    private(set) var isShowingAllChips = false

    private let chipRegroupDelay: Duration
    private var chipRegroupTask: Task<Void, Never>?
    private var isHoveringChips = false

    #if DEBUG
    var panelFrameForTesting: CGRect? { panel?.frame }
    #endif

    init(
        userDefaults: UserDefaults = .standard,
        chipRegroupDelay: Duration = .seconds(5)
    ) {
        self.userDefaults = userDefaults
        self.chipRegroupDelay = chipRegroupDelay
    }

    var isEnabled: Bool {
        _ = enabledRevision
        guard userDefaults.object(forKey: DefaultsKey.enabled) != nil else { return true }
        return userDefaults.bool(forKey: DefaultsKey.enabled)
    }

    func configure(
        model: HerdrAppModel,
        session: HerdrHudSession,
        notes: HerdrHudNotesState,
        fontScale: HerdrFontScaleStore
    ) {
        guard !isConfigured else { return }
        isConfigured = true
        self.session = session
        self.notes = notes
        lastNotesLayout = notes.layout
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
        panel.onCancel = { [weak self] in self?.handleCancel() }
        panel.contentView = NSHostingView(
            rootView: HerdrHudRootView(
                model: model,
                controller: self,
                session: session,
                notes: notes,
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
        notes?.closeNote()
        regroupChips()
        isExpanded = true
        if notes?.isHudExpanded == false { notes?.isHudExpanded = true }
        session?.isCollapsed = false
        applyFrame(animated: true)
        panel.makeKeyAndOrderFront(nil)
        focusRequest &+= 1
        session?.markSeen()
    }

    func collapse() {
        guard let panel else { return }
        isExpanded = false
        if notes?.isHudExpanded == true { notes?.isHudExpanded = false }
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
        notes?.closeNote()
        regroupChips()
        userDefaults.set(enabled, forKey: DefaultsKey.enabled)
        enabledRevision &+= 1
        guard let panel else { return }

        if enabled {
            installHotKey()
            isExpanded = false
            if notes?.isHudExpanded == true { notes?.isHudExpanded = false }
            session?.isCollapsed = true
            applyFrame(animated: false)
            panel.orderFrontRegardless()
        } else {
            isExpanded = false
            if notes?.isHudExpanded == true { notes?.isHudExpanded = false }
            session?.isCollapsed = true
            applyFrame(animated: false)
            panel.orderOut(nil)
            hotKey?.unregister()
        }
    }

    func setCollapsedChipCount(_ count: Int) {
        let clampedCount = min(max(0, count), HerdrHudPlacement.maxExpandedChips)
        guard collapsedChipCount != clampedCount else { return }
        collapsedChipCount = clampedCount
        if !isExpanded {
            applyFrame(animated: true)
        }
    }

    /// Reveal every session the `+N` control had grouped away.
    func showAllChips() {
        chipRegroupTask?.cancel()
        chipRegroupTask = nil
        guard !isShowingAllChips else { return }
        isShowingAllChips = true
    }

    func regroupChips() {
        chipRegroupTask?.cancel()
        chipRegroupTask = nil
        guard isShowingAllChips else { return }
        isShowingAllChips = false
    }

    /// Hovering holds the revealed list open; leaving it starts the regroup
    /// countdown. Deliberately a grace period rather than an immediate collapse
    /// — the pointer crosses the gaps between chips on its way to one of them.
    func setHoveringChips(_ hovering: Bool) {
        isHoveringChips = hovering
        guard isShowingAllChips else { return }
        chipRegroupTask?.cancel()
        guard !hovering else {
            chipRegroupTask = nil
            return
        }
        chipRegroupTask = Task { [weak self, chipRegroupDelay] in
            try? await Task.sleep(for: chipRegroupDelay)
            guard !Task.isCancelled, let self, !self.isHoveringChips else { return }
            self.chipRegroupTask = nil
            self.isShowingAllChips = false
        }
    }

    func notesLayoutDidChange() {
        guard let panel else { return }
        let currentLayout = notes?.layout ?? .hidden
        let newFrame = frame(for: isExpanded)
        if newFrame != panel.frame {
            applyFrame(animated: Self.shouldAnimateNotesFrameTransition(from: lastNotesLayout, to: currentLayout))
        }
        if case .card = lastNotesLayout,
           !Self.isCardLayout(currentLayout),
           !isExpanded,
           panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        lastNotesLayout = currentLayout
    }

    /// Compact, hidden, and row layouts are all hover-driven. Resizing the
    /// AppKit panel with an animator for those transitions moves the window's
    /// origin while SwiftUI is also changing its content, which makes the HUD
    /// appear to leave the screen. Resize those layouts immediately and let the
    /// notes view own the fade. Card presentation can retain its deliberate
    /// panel animation.
    static func shouldAnimateNotesFrameTransition(
        from oldLayout: HerdrHudPlacement.NotesLayout,
        to newLayout: HerdrHudPlacement.NotesLayout
    ) -> Bool {
        isCardLayout(oldLayout) || isCardLayout(newLayout)
    }

    func openNote(_ id: UUID) {
        guard let panel, let notes else { return }
        if isExpanded {
            isExpanded = false
            session?.isCollapsed = true
            if notes.isHudExpanded { notes.isHudExpanded = false }
        }
        notes.openNote(id)
        applyFrame(animated: true)
        panel.makeKeyAndOrderFront(nil)
        noteFocusRequest &+= 1
    }

    func closeNote() { notes?.closeNote() }

    func handleCancel() {
        if notes?.openNoteID != nil {
            closeNote()
        } else {
            collapse()
        }
    }

    private static func isCardLayout(_ layout: HerdrHudPlacement.NotesLayout) -> Bool {
        if case .card = layout { return true }
        return false
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
        frameAnimationGeneration &+= 1
        let generation = frameAnimationGeneration
        panel.setFrame(frame(for: isExpanded), display: true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.frameAnimationGeneration == generation else { return }
            self.isProgrammaticMove = false
        }
    }

    private func applyFrame(animated: Bool) {
        guard let panel else { return }
        let newFrame = frame(for: isExpanded)
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        isProgrammaticMove = true
        frameAnimationGeneration &+= 1
        let generation = frameAnimationGeneration
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }, completionHandler: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.frameAnimationGeneration == generation else { return }
                    self.isProgrammaticMove = false
                }
            })
        } else {
            panel.setFrame(newFrame, display: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.frameAnimationGeneration == generation else { return }
                self.isProgrammaticMove = false
            }
        }
    }

    private func frame(for isExpanded: Bool) -> CGRect {
        HerdrHudPlacement.frame(
            isExpanded: isExpanded,
            visibleFrame: visibleFrame(for: panel),
            topRightOffset: placementOffset,
            chipCount: isExpanded ? 0 : collapsedChipCount,
            notesSize: HerdrHudPlacement.notesContentSize(notes?.layout ?? .hidden, isExpanded: isExpanded)
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
