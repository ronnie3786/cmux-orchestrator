import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// The composer's Return table. Two invariants outrank every individual row:
/// 1. ⌘Return never sends and never commits a skill — it breaks the line, which
///    is the whole reason a multi-line prompt is typeable at all.
/// 2. ⇧/⌥Return stay passthrough, because the field editor breaks the line at
///    the caret and this code cannot.
@Suite("Composer return key")
struct ComposerReturnKeyRouterTests {
    @Test("Plain Return sends")
    func plainReturnSends() {
        #expect(outcome([]) == .send)
    }

    @Test("Command+Return always breaks the line, never sends")
    func commandReturnInsertsANewline() {
        #expect(outcome(.command) == .insertNewline)
        #expect(outcome([.command, .shift]) == .insertNewline)
        #expect(outcome([.command, .option]) == .insertNewline)
    }

    @Test("Command+Return outranks a visible skills HUD")
    func commandReturnBeatsThePalette() {
        #expect(outcome(.command, paletteVisible: true) == .insertNewline)
    }

    @Test("Shift and Option Return stay with the field editor")
    func modifiedReturnsPassThrough() {
        #expect(outcome(.shift) == .passthrough)
        #expect(outcome(.option) == .passthrough)
        #expect(outcome(.shift, paletteVisible: true) == .passthrough)
        #expect(outcome(.option, paletteVisible: true) == .passthrough)
    }

    @Test("Return commits the highlighted skill while the HUD is up")
    func plainReturnAcceptsASkill() {
        #expect(outcome([], paletteVisible: true) == .acceptSkill)
    }

    @Test("The onSubmit backstop reads the same table from the live modifiers")
    func submitBackstopMirrorsTheKeyTable() {
        #expect(ComposerReturnKeyRouter.submitOutcome(
            isSkillsPaletteVisible: false, flags: .command) == .insertNewline)
        #expect(ComposerReturnKeyRouter.submitOutcome(
            isSkillsPaletteVisible: false, flags: []) == .send)
        #expect(ComposerReturnKeyRouter.submitOutcome(
            isSkillsPaletteVisible: true, flags: .command) == .insertNewline)
    }

    private func outcome(
        _ modifiers: EventModifiers,
        paletteVisible: Bool = false
    ) -> ComposerReturnKeyRouter.Outcome {
        ComposerReturnKeyRouter.outcome(
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option),
            isSkillsPaletteVisible: paletteVisible
        )
    }
}
