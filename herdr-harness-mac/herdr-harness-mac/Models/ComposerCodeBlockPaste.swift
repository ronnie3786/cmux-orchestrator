import AppKit

/// Pastes literal Markdown fences without trimming or executing clipboard text.
enum ComposerCodeBlockPaste {
    static func fenced(_ text: String) -> String {
        // A longer fence keeps a pasted snippet containing its own fences intact.
        let longestRun = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return fence + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence
    }

    static func inserting(_ text: String, into draft: String, selection: NSRange? = nil) -> String {
        let source = draft as NSString
        let range = selection ?? NSRange(location: source.length, length: 0)
        guard range.location != NSNotFound, range.location <= source.length,
              range.length <= source.length - range.location else { return draft }
        let prefix = source.substring(to: range.location)
        let suffix = source.substring(from: NSMaxRange(range))
        return prefix + (prefix.isEmpty || prefix.hasSuffix("\n") ? "" : "\n")
            + fenced(text) + (suffix.isEmpty || suffix.hasPrefix("\n") ? "" : "\n") + suffix
    }

    @MainActor
    @discardableResult
    static func paste(into draft: inout String, pasteboard: NSPasteboard = .general) -> Bool {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return false }
        // Check the editor belongs to this draft. A click can leave another field
        // focused, and it must never receive the clipboard content by accident.
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
           editor.isEditable, editor.string == draft {
            let range = editor.selectedRange()
            let draftLength = (draft as NSString).length
            guard range.location != NSNotFound, range.location <= draftLength,
                  range.length <= draftLength - range.location else { return false }
            let result = inserting(text, into: draft, selection: range)
            let unchangedLength = (draft as NSString).length - range.length
            let insertedLength = (result as NSString).length - unchangedLength
            guard insertedLength >= 0 else { return false }
            let insertion = (result as NSString).substring(with: NSRange(location: range.location, length: insertedLength))
            editor.insertText(insertion, replacementRange: range)
            draft = editor.string
        } else {
            draft = inserting(text, into: draft)
        }
        return true
    }
}
