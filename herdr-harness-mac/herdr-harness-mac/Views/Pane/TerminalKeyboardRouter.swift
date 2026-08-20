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
    private var pendingPaneID: String?
    private var coalesceTask: Task<Void, Never>?
    private var lastSend: Task<Void, Never>?
    private var client: HerdrAPIClient?
    private var clientGeneration: Int?

    /// Classifies one keystroke and puts it on the wire.
    ///
    /// Returns `.ignored` for anything the terminal has no business eating, so
    /// SwiftUI can route it onwards (menus, the composer, system shortcuts).
    func handle(_ press: KeyPress, model: HerdrAppModel, pane: HerdrPane) -> KeyPress.Result {
        guard model.canControl else { return .ignored }

        switch TerminalKeyboardMapping.outcome(for: press) {
        case .ignored:
            return .ignored
        case let .text(text):
            append(text, paneID: pane.id, model: model)
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
        guard !pendingText.isEmpty, let paneID = pendingPaneID else { return }

        let text = pendingText
        pendingText = ""
        pendingPaneID = nil
        enqueue { [weak self] in
            await self?.sendText(text, toPaneID: paneID, model: model)
        }
    }

    /// Drops buffered characters without sending them — for when the view goes
    /// away or swaps panes. Those keystrokes were meant for a session that is
    /// no longer on screen.
    func discardPendingInput() {
        coalesceTask?.cancel()
        coalesceTask = nil
        pendingText = ""
        pendingPaneID = nil
    }

    // MARK: - Buffering

    private func append(_ text: String, paneID: String, model: HerdrAppModel) {
        if pendingPaneID != paneID {
            flush(model: model)
        }
        pendingPaneID = paneID
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
        enqueue { await model.sendKeys(keys, to: pane) }
    }

    /// Serialises sends. tmux applies input in arrival order, so requests must
    /// not be allowed to overlap.
    private func enqueue(_ operation: @escaping @Sendable @MainActor () async -> Void) {
        let previous = lastSend
        lastSend = Task { @MainActor in
            if let previous {
                _ = await previous.value
            }
            await operation()
        }
    }

    // MARK: - Transport

    private func sendText(_ text: String, toPaneID paneID: String, model: HerdrAppModel) async {
        guard !model.isDemoMode,
              model.canControl,
              model.pane(id: paneID) != nil,
              let client = apiClient(for: model)
        else { return }

        do {
            try await client.sendText(toPane: paneID, text: text, submit: false)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    /// `HerdrAppModel` keeps its client private, so the router builds its own
    /// from the same active configuration and rebuilds it whenever the app
    /// reconnects. `activeServerConfiguration` is already nil in demo mode and
    /// whenever the connection generation has moved on, so this cannot outlive
    /// a connection.
    private func apiClient(for model: HerdrAppModel) -> HerdrAPIClient? {
        guard let configuration = model.activeServerConfiguration else {
            client = nil
            clientGeneration = nil
            return nil
        }

        if let client, clientGeneration == model.connectionGeneration {
            return client
        }

        let created = HerdrAPIClient(configuration: configuration)
        client = created
        clientGeneration = model.connectionGeneration
        return created
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
