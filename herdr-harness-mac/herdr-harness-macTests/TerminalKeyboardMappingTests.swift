import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Mac-only. On iOS the terminal only ever received taps from `TerminalKeyDeck`,
/// so `TerminalPresetKey.primaryRow`/`secondaryRow` was the whole contract. The
/// Mac app accepts real keystrokes, which puts a classifier between the keyboard
/// and tmux — this suite is that classifier's table.
///
/// Two invariants matter more than any single row:
/// 1. ⌘ chords are never eaten, or the menu bar stops working while a terminal
///    has focus.
/// 2. Named keys go out on `send-keys` using the exact same wire vocabulary the
///    on-screen deck uses, so both input paths are indistinguishable to tmux.
@Suite("Terminal keystroke classification")
struct TerminalKeyboardMappingTests {
    @Test("Plain typing goes out as literal send-text")
    func typedCharactersBecomeText() {
        #expect(outcome(.init("a"), "a") == .text("a"))
        #expect(outcome(.init("A"), "A", .shift) == .text("A"))
        #expect(outcome(.space, " ") == .text(" "))
        #expect(outcome(.init("|"), "|", .shift) == .text("|"))
        // ⌥ is a legitimate text-composition modifier on Mac: ⌥5 types "∞".
        #expect(outcome(.init("5"), "\u{221E}", .option) == .text("\u{221E}"))
    }

    @Test("Named keys use the same wire vocabulary as the on-screen deck")
    func namedKeysMatchThePresetDeck() {
        let expected: [(KeyEquivalent, TerminalPresetKey)] = [
            (.upArrow, .up),
            (.downArrow, .down),
            (.leftArrow, .left),
            (.rightArrow, .right),
            (.tab, .tab),
            (.return, .enter),
            (.escape, .escape),
            (.delete, .backspace),
        ]

        for (key, preset) in expected {
            #expect(outcome(key, "") == .keys([preset.rawValue]))
        }

        // Every deck key is reachable from the keyboard, and nothing else is.
        let routable = Set(expected.map(\.1))
        #expect(routable == Set(TerminalPresetKey.allCases))
        #expect(Set(TerminalPresetKey.primaryRow + TerminalPresetKey.secondaryRow) == routable)
    }

    @Test("Command chords always belong to the menus")
    func commandChordsAreNeverIntercepted() {
        #expect(outcome(.init("c"), "c", .command) == .ignored)
        #expect(outcome(.init("k"), "k", .command) == .ignored)
        #expect(outcome(.init("v"), "v", .command) == .ignored)
        #expect(outcome(.return, "\r", .command) == .ignored)
        #expect(outcome(.upArrow, "", .command) == .ignored)
        #expect(outcome(.init("["), "[", [.command, .shift]) == .ignored)
    }

    @Test("Only the verified ⌃C chord is sent; other control chords pass through")
    func controlChordHandling() {
        #expect(TerminalKeyboardMapping.interruptKeyName == "ctrl+c")
        #expect(outcome(.init("c"), "c", .control) == .keys(["ctrl+c"]))
        #expect(outcome(.init("C"), "C", [.control, .shift]) == .keys(["ctrl+c"]))
        // Some event sources deliver ⌃C as the ETX control character instead.
        #expect(outcome(.init("c"), "\u{03}", .control) == .keys(["ctrl+c"]))

        // Unverified chords are handed back to SwiftUI rather than guessed at.
        #expect(outcome(.init("d"), "d", .control) == .ignored)
        #expect(outcome(.init("z"), "z", .control) == .ignored)
        #expect(outcome(.upArrow, "", .control) == .ignored)
        #expect(outcome(.tab, "\t", .option) == .ignored)
    }

    @Test("Function keys and stray control characters never reach the shell")
    func nonTypableInputIsIgnored() {
        // F1 and Home arrive as private-use scalars; typed literally they would
        // be mojibake in the shell.
        #expect(outcome(.init("\u{F704}"), "\u{F704}") == .ignored)
        #expect(outcome(.init("\u{F729}"), "\u{F729}") == .ignored)
        #expect(outcome(.init("\u{01}"), "\u{01}") == .ignored)
        #expect(outcome(.init("a"), "") == .ignored)
    }

    private func outcome(
        _ key: KeyEquivalent,
        _ characters: String,
        _ modifiers: EventModifiers = []
    ) -> TerminalKeyboardMapping.Outcome {
        TerminalKeyboardMapping.outcome(key: key, characters: characters, modifiers: modifiers)
    }
}
