import AppKit
import SwiftUI

/// What the composer does when Return comes in.
///
/// Pure, so the rule table can be read (and tested) without a view, a window
/// or a focused text field — the same bargain `TerminalKeyboardMapping` makes
/// for the terminal surface. The composers own the text field and the key
/// events; every ordering question about Return is answered here.
enum ComposerReturnKeyRouter {
    enum Outcome: Equatable, Sendable {
        /// Commit the highlighted `$`-skill. Only ever reachable with the HUD up.
        case acceptSkill
        /// Break the line ourselves, because the field editor is never going to
        /// see this keystroke.
        case insertNewline
        /// Hand the chord back to the field editor, which breaks the line at the
        /// caret better than we can.
        case passthrough
        /// Send the prompt.
        case send
    }

    /// The whole table, in one place.
    ///
    /// ⌘Return outranks everything, including a visible skills HUD. It is the
    /// most deliberate thing a user can type into a multi-line field, and
    /// turning a deliberate "break this line" into a commit — or worse, into a
    /// send — is exactly the surprise this router exists to prevent. The HUD
    /// closes on its own afterwards: a newline is whitespace, and
    /// `ComposerSkillsPalette` already treats whitespace after a `$token` as
    /// the end of that token.
    static func outcome(
        command: Bool,
        shift: Bool,
        option: Bool,
        isSkillsPaletteVisible: Bool
    ) -> Outcome {
        if command { return .insertNewline }
        if isSkillsPaletteVisible, !shift, !option { return .acceptSkill }
        // ⇧/⌥Return are already bound to `insertNewlineIgnoringFieldEditor:`.
        // The field editor knows the caret and we do not, so let it win.
        if shift || option { return .passthrough }
        return .send
    }

    static func outcome(for press: KeyPress, isSkillsPaletteVisible: Bool) -> Outcome {
        outcome(
            command: press.modifiers.contains(.command),
            shift: press.modifiers.contains(.shift),
            option: press.modifiers.contains(.option),
            isSkillsPaletteVisible: isSkillsPaletteVisible
        )
    }

    /// The same table, for `onSubmit`, which carries no modifiers.
    ///
    /// A vertical-axis `TextField` makes ⌘Return its default action, and
    /// SwiftUI dispatches ⌘ chords through `performKeyEquivalent` — ahead of
    /// `onKeyPress`. So a ⌘Return can reach `onSubmit` without
    /// `outcome(for:isSkillsPaletteVisible:)` ever having run, and would arrive
    /// looking exactly like a plain Return. The Command key is still physically
    /// down at that instant, which makes the live modifier flags the only
    /// honest witness available. `flags` is a parameter purely so the tests can
    /// supply their own.
    static func submitOutcome(
        isSkillsPaletteVisible: Bool,
        flags: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) -> Outcome {
        outcome(
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            isSkillsPaletteVisible: isSkillsPaletteVisible
        )
    }
}

/// Puts a line break in the draft when the field editor will not.
///
/// `.handled` means the keystroke stops here, so the newline has to be inserted
/// by hand. SwiftUI publishes no caret for `TextField`, but AppKit does: while
/// the composer has focus the window's first responder IS its field editor, and
/// `insertNewlineIgnoringFieldEditor(_:)` on that responder is the very method
/// ⇧Return is already bound to. Going through it puts the break at the caret,
/// keeps undo and selection intact, and updates the SwiftUI binding through the
/// same delegate callbacks ordinary typing uses.
///
/// The append fallback exists for the cases where there is no field editor to
/// find — an offscreen `NSHostingView` render, a focus race. It puts the break
/// at the end of the draft, which is wrong only for a mid-string caret and
/// never loses the keystroke outright.
@MainActor
enum ComposerNewlineInserter {
    /// Returns `true` when the break landed at the caret.
    @discardableResult
    static func insertNewline(appendingTo draft: inout String) -> Bool {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
            editor.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        draft.append("\n")
        return false
    }
}
