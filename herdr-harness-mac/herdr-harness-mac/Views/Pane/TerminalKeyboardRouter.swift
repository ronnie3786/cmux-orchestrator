import Foundation
import SwiftUI

/// Sends real Mac keystrokes to the pane's tmux session.
///
/// Two wires, one ordering guarantee. Printable characters coalesce for a few
/// milliseconds and go out as `POST send-text` (tmux types them literally);
/// arrows, tab, return, escape, delete and ⌃C go out as `POST send-keys` using
/// the same wire names `TerminalKeyDeck` uses. Every request is chained behind
/// the previous one, so `ls` followed by Return can never arrive as Return
/// followed by `ls`.
///
/// Nothing is echoed locally. The frame stream stays the only source of truth
/// for what the terminal shows, and `isFollowing` is never touched — typing
/// must not fight the follow toggle.
@MainActor
final class TerminalKeyboardRouter {
    /// How long typed characters wait for company before being sent. Long
    /// enough to fold a fast typist's burst into one request, short enough that
    /// a single keystroke still feels immediate.
    private static let coalesceWindow = Duration.milliseconds(30)

    private var pendingText = ""
    private var pendingPane: HerdrPane?
    private var coalesceTask: Task<Void, Never>?
    private var lastSend: Task<Void, Never>?
    private var sendEpoch = 0
    private var queuedSendCount = 0
    private var didReportDroppedInput = false

    /// Classifies one keystroke and puts it on the wire.
    ///
    /// Returns `.ignored` for anything the terminal has no business eating, so
    /// SwiftUI can route it onwards (menus, the composer, system shortcuts).
    func handle(_ press: KeyPress, model: HerdrAppModel, pane: HerdrPane) -> KeyPress.Result {
        guard model.canControl(machineID: pane.machineID) else { return .ignored }

        switch TerminalKeyboardMapping.outcome(for: press) {
        case .ignored:
            return .ignored
        case let .text(text):
            append(text, pane: pane, model: model)
            return .handled
        case let .keys(keys):
            send(keys: keys, to: pane, model: model)
            return .handled
        }
    }

    /// Flushes the coalescing buffer immediately. Called when the terminal
    /// loses focus so a half-typed line is not left hanging in the app.
    func flush(model: HerdrAppModel) {
        coalesceTask?.cancel()
        coalesceTask = nil
        guard !pendingText.isEmpty, let pane = pendingPane else { return }

        let text = pendingText
        pendingText = ""
        pendingPane = nil
        enqueueText(text, to: pane, model: model)
    }

    /// Places an already-coalesced text payload on the serial terminal wire.
    /// Keeping this separate from `flush` makes every text route use the same
    /// pane-aware model handoff.
    func enqueueText(_ text: String, to pane: HerdrPane, model: HerdrAppModel) {
        enqueue(model: model) {
            await model.sendText(text, to: pane)
        }
    }

    /// Drops buffered characters without sending them — for when the view goes
    /// away or swaps panes. Those keystrokes were meant for a session that is
    /// no longer on screen.
    func discardPendingInput() {
        coalesceTask?.cancel()
        coalesceTask = nil
        pendingText = ""
        pendingPane = nil
    }

    // MARK: - Buffering

    private func append(_ text: String, pane: HerdrPane, model: HerdrAppModel) {
        if pendingPane?.id != pane.id {
            flush(model: model)
        }
        pendingPane = pane
        pendingText += text

        guard coalesceTask == nil else { return }
        coalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.coalesceWindow)
            guard let self, !Task.isCancelled else { return }
            coalesceTask = nil
            flush(model: model)
        }
    }

    private func send(keys: [String], to pane: HerdrPane, model: HerdrAppModel) {
        // Anything already typed belongs in front of the key that follows it.
        flush(model: model)
        enqueue(model: model) { await model.sendKeys(keys, to: pane) }
    }

    /// Serialises sends. tmux applies input in arrival order, so requests must
    /// not be allowed to overlap.
    func enqueue(
        model: HerdrAppModel,
        _ operation: @escaping @Sendable @MainActor () async -> Bool
    ) {
        guard queuedSendCount < 8 else {
            if !didReportDroppedInput {
                didReportDroppedInput = true
                model.toastMessage = "Input backlog, dropped pending input"
            }
            return
        }
        queuedSendCount += 1
        let epoch = sendEpoch
        let previous = lastSend
        lastSend = Task { @MainActor [weak self] in
            if let previous {
                _ = await previous.value
            }
            guard let self else { return }
            defer {
                self.queuedSendCount -= 1
                if self.queuedSendCount == 0 { self.didReportDroppedInput = false }
            }
            guard epoch == self.sendEpoch, !Task.isCancelled else { return }
            guard await operation() else {
                self.dropRemainingSends()
                return
            }
        }
    }

    private func dropRemainingSends() {
        // Keep the task chain intact so stale work drains in order and a new
        // send never overlaps work that was already queued.
        sendEpoch &+= 1
    }
}

/// Keystroke → wire format. Pure, so the rules can be read (and tested) without
/// a view, a window, or a server.
enum TerminalKeyboardMapping {
    enum Outcome: Equatable, Sendable {
        /// Literal characters for `POST send-text`.
        case text(String)
        /// Named keys for `POST send-keys`.
        case keys([String])
        /// Not ours — let SwiftUI route it.
        case ignored
    }

    /// The one chord whose server-side name is proven in this app;
    /// `PaneActionsMenu`'s Interrupt sends the same string.
    static let interruptKeyName = "ctrl+c"

    static func outcome(for press: KeyPress) -> Outcome {
        outcome(key: press.key, characters: press.characters, modifiers: press.modifiers)
    }

    static func outcome(
        key: KeyEquivalent,
        characters: String,
        modifiers: EventModifiers
    ) -> Outcome {
        // Menu commands own every ⌘ chord. Never steal them.
        if modifiers.contains(.command) { return .ignored }

        if let name = keyName(for: key) {
            // ⌃ or ⌥ plus a named key needs a chord name we have not verified
            // against cmux's key table, so let it pass rather than guess.
            guard !modifiers.contains(.control), !modifiers.contains(.option) else {
                return .ignored
            }
            return .keys([name])
        }

        if modifiers.contains(.control) {
            return isInterrupt(key: key, characters: characters)
                ? .keys([interruptKeyName])
                : .ignored
        }

        return isTypable(characters) ? .text(characters) : .ignored
    }

    /// The eight names tmux is known to accept — the same vocabulary the
    /// on-screen deck sends.
    private static func keyName(for key: KeyEquivalent) -> String? {
        switch key {
        case KeyEquivalent.upArrow: TerminalPresetKey.up.rawValue
        case KeyEquivalent.downArrow: TerminalPresetKey.down.rawValue
        case KeyEquivalent.leftArrow: TerminalPresetKey.left.rawValue
        case KeyEquivalent.rightArrow: TerminalPresetKey.right.rawValue
        case KeyEquivalent.tab: TerminalPresetKey.tab.rawValue
        case KeyEquivalent.return: TerminalPresetKey.enter.rawValue
        case KeyEquivalent.escape: TerminalPresetKey.escape.rawValue
        case KeyEquivalent.delete: TerminalPresetKey.backspace.rawValue
        default: nil
        }
    }

    private static func isInterrupt(key: KeyEquivalent, characters: String) -> Bool {
        // ⌃C surfaces as the letter or as the ETX control character depending
        // on how the event was synthesised. Accept both.
        key.character == "c" || key.character == "C" || characters == "\u{03}"
    }

    /// Function keys, Home/End, page keys and the arrows arrive as private-use
    /// scalars; typed literally they would be mojibake in the shell. Only real
    /// text goes out.
    private static let functionKeyScalars: ClosedRange<UInt32> = 0xF700...0xF8FF

    private static func isTypable(_ characters: String) -> Bool {
        guard !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !functionKeyScalars.contains(scalar.value)
        }
    }
}

extension View {
    /// Makes this view the pane's keyboard surface: click it, and every
    /// keystroke goes to the tmux session instead of to the app.
    func terminalKeyboardRouting(
        router: TerminalKeyboardRouter,
        model: HerdrAppModel,
        pane: HerdrPane,
        isFocused: FocusState<Bool>.Binding
    ) -> some View {
        modifier(
            TerminalKeyboardRoutingModifier(
                router: router,
                model: model,
                pane: pane,
                isFocused: isFocused
            )
        )
    }
}

private struct TerminalKeyboardRoutingModifier: ViewModifier {
    let router: TerminalKeyboardRouter
    let model: HerdrAppModel
    let pane: HerdrPane
    var isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content
            .focusable()
            // The accent ring is drawn by PaneTerminalView; the system ring
            // would sit outside the terminal's own border and fight it.
            .focusEffectDisabled()
            .focused(isFocused)
            // Simultaneous so click-to-focus never costs the user a text
            // selection drag inside the output.
            .simultaneousGesture(
                TapGesture().onEnded { isFocused.wrappedValue = true }
            )
            .onKeyPress(phases: [.down, .repeat]) { press in
                router.handle(press, model: model, pane: pane)
            }
            .onChange(of: isFocused.wrappedValue) { _, hasFocus in
                if !hasFocus { router.flush(model: model) }
            }
            .onChange(of: pane.id) { _, _ in
                router.discardPendingInput()
            }
            // No accessibility identifier here on purpose: PaneTerminalView's
            // `terminal-<paneID>` is the one UI tests look for, and a second one
            // on the wrapper would shadow it.
            .help("Click to type straight into this pane")
    }
}
