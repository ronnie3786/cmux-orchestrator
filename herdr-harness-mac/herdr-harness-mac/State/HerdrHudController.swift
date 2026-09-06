import AppKit
import Carbon.HIToolbox
import Observation
import QuartzCore
import SwiftUI

final class HerdrHudPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A `.nonactivatingPanel` is key while another app owns the menu bar, so
    /// AppKit may never offer the event to our own main menu — and Format ▸
    /// Font is where ⌘B/⌘I/⌘U live. Offer it by hand in that case, so the note
    /// editor formats whether or not Herdr happens to be frontmost.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard !NSApp.isActive, let mainMenu = NSApp.mainMenu else { return false }
        return mainMenu.performKeyEquivalent(with: event)
    }

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
    private(set) var quickVoice: QuickVoicePanelController?
    private var lastNotesLayout: HerdrHudPlacement.NotesLayout = .hidden
    private var placementOffset = HerdrHudPlacement.defaultOffset()
    private var notificationTokens: [NSObjectProtocol] = []
    private var isConfigured = false
    private var isProgrammaticMove = false
    private var needsFrameSyncAfterDrag = false
    /// Hover-driven notes layouts can start a new frame animation while the
    /// previous one is still running. Only the newest animation's completion
    /// may clear `isProgrammaticMove`, or an intermediate frame gets persisted
    /// as the user's chosen placement.
    private var frameAnimationGeneration = 0
    private var enabledRevision = 0

    private(set) var isExpanded = false
    private(set) var isDraggingPanel = false
    /// Set while a HUD prompt runs with the card auto-collapsed, so the run's
    /// completion knows it is allowed to reopen. `isExpanded == false` cannot
    /// answer that on its own — it also means "user collapsed", "a note is
    /// open" and "the HUD is disabled" — so intent gets its own flag, cleared
    /// by every user action that means "leave it shut".
    private(set) var isAwaitingRunAutoOpen = false
    private(set) var focusRequest = 0
    private(set) var noteFocusRequest = 0
    private(set) var collapsedChipCount = 0
    private(set) var isVoiceReplyCardVisible = false
    private(set) var isCollapsedResultRailVisible = false
    /// Whether the `+N` control has been clicked to reveal the grouped
    /// sessions. Regrouped `chipRegroupDelay` after the pointer leaves them.
    private(set) var isShowingAllChips = false

    private let chipRegroupDelay: Duration
    private var chipRegroupTask: Task<Void, Never>?
    private var isHoveringChips = false

    #if DEBUG
    var panelFrameForTesting: CGRect? { panel?.frame }
    var placementOffsetForTesting: CGSize { placementOffset }
    func setPanelFrameForTesting(_ frame: CGRect) { panel?.setFrame(frame, display: true) }
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
        fontScale: HerdrFontScaleStore,
        quickVoice: QuickVoicePanelController? = nil
    ) {
        guard !isConfigured else { return }
        isConfigured = true
        self.session = session
        self.notes = notes
        self.quickVoice = quickVoice
        quickVoice?.configure(model: model, hud: self)
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
        panel.isMovableByWindowBackground = false
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
        isAwaitingRunAutoOpen = false
        quickVoice?.collapse()
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
        isAwaitingRunAutoOpen = false
        guard let panel else { return }
        isExpanded = false
        if notes?.isHudExpanded == true { notes?.isHudExpanded = false }
        session?.isCollapsed = true
        applyFrame(animated: true)
        if panel.isKeyWindow {
            refocusPanelWithoutFade(panel)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Gets the HUD out of the way for the length of a run.
    ///
    /// Only collapses a card that is actually open — a submit from a HUD the
    /// user already tucked away should not arm an auto-open they never asked
    /// for. Returns whether the caller now owes an `endRunAutoCollapse()`.
    @discardableResult
    func beginRunAutoCollapse() -> Bool {
        guard isEnabled, isExpanded, panel != nil, !isDraggingPanel else { return false }
        collapse()
        isAwaitingRunAutoOpen = true
        return true
    }

    /// Reopens after the run finishes, unless the user has since taken the HUD
    /// somewhere else. `summon()` clears the flag, so this is idempotent.
    func endRunAutoCollapse() {
        guard isAwaitingRunAutoOpen else { return }
        isAwaitingRunAutoOpen = false
        guard isEnabled, panel != nil, !isExpanded, !isDraggingPanel,
              notes?.openNoteID == nil
        else { return }
        summon()
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
        if !enabled { quickVoice?.collapse() }
        if !enabled { isAwaitingRunAutoOpen = false }
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

    func setVoiceReplyCardVisible(_ isVisible: Bool) {
        guard isVoiceReplyCardVisible != isVisible else { return }
        isVoiceReplyCardVisible = isVisible
        applyFrame(animated: true)
    }

    func presentQuickVoice() {
        isAwaitingRunAutoOpen = false
        if !isEnabled { setEnabled(true) }
        notes?.closeNote()
        isExpanded = false
        notes?.isHudExpanded = false
        session?.isCollapsed = true
        applyFrame(animated: false)
        panel?.makeKeyAndOrderFront(nil)
    }

    func quickVoiceLayoutDidChange() { applyFrame(animated: false) }

    func setCollapsedChipCount(_ count: Int) {
        let clampedCount = min(max(0, count), HerdrHudPlacement.maxCollapsedRows)
        guard collapsedChipCount != clampedCount else { return }
        collapsedChipCount = clampedCount
        if !isExpanded {
            applyFrame(animated: true)
        }
    }

    func setCollapsedResultRailVisible(_ isVisible: Bool) {
        guard isCollapsedResultRailVisible != isVisible else { return }
        isCollapsedResultRailVisible = isVisible
        if !isExpanded {
            applyFrame(animated: true)
        }
    }

    func beginPanelDrag() {
        isDraggingPanel = true
        notes?.isHoverSuspended = true
        needsFrameSyncAfterDrag = false
    }

    func endPanelDrag() {
        isDraggingPanel = false
        if let panel {
            let visibleFrame = visibleFrame(for: panel)
            let offset = HerdrHudPlacement.offset(forFrame: panel.frame, visibleFrame: visibleFrame)
            placementOffset = HerdrHudPlacement.reclamp(
                topRightOffset: offset,
                isExpanded: isExpanded,
                visibleFrame: visibleFrame
            )
            savePlacementOffset()
        }
        notes?.isHoverSuspended = false
        if needsFrameSyncAfterDrag {
            needsFrameSyncAfterDrag = false
            applyFrame(animated: false)
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
           !isDraggingPanel,
           panel.isKeyWindow {
            refocusPanelWithoutFade(panel)
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
        isAwaitingRunAutoOpen = false
        quickVoice?.collapse()
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
        if quickVoice?.isExpanded == true {
            quickVoice?.collapse()
        } else if notes?.openNoteID != nil {
            closeNote()
        } else {
            collapse()
        }
    }

    private static func isCardLayout(_ layout: HerdrHudPlacement.NotesLayout) -> Bool {
        if case .card = layout { return true }
        return false
    }

    private func refocusPanelWithoutFade(_ panel: HerdrHudPanel) {
        let previousBehavior = panel.animationBehavior
        panel.animationBehavior = .none
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        panel.animationBehavior = previousBehavior
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
        guard let panel else { return }
        if isDraggingPanel {
            placementOffset = HerdrHudPlacement.offset(
                forFrame: panel.frame,
                visibleFrame: visibleFrame(for: panel)
            )
            return
        }
        guard !isProgrammaticMove else { return }
        placementOffset = HerdrHudPlacement.offset(
            forFrame: panel.frame,
            visibleFrame: visibleFrame(for: panel)
        )
        savePlacementOffset()
    }

    private func reclampPlacement() {
        if isDraggingPanel { return }
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
        if isDraggingPanel {
            needsFrameSyncAfterDrag = true
            return
        }
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
            hasResultRail: !isExpanded && isCollapsedResultRailVisible,
            notesSize: HerdrHudPlacement.notesContentSize(notes?.layout ?? .hidden, isExpanded: isExpanded),
            voiceReplySize: isVoiceReplyCardVisible ? HerdrHudPlacement.voiceReplyCardSize : .zero,
            quickVoiceSize: quickVoice?.isExpanded == true ? HerdrHudPlacement.quickVoiceCardSize : .zero
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
