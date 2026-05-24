import SwiftUI
import Testing
@testable import cmux_harness_ios

@MainActor
struct HarnessParsingTests {
    @Test
    func unifiedDiffParserTracksLineNumbersAndReviewSides() {
        let diff = """
        diff --git a/App.swift b/App.swift
        index 123..456 100644
        --- a/App.swift
        +++ b/App.swift
        @@ -10,3 +10,4 @@
         let same = true
        -oldCall()
        +newCall()
        +addedCall()
        """

        let lines = parseUnifiedDiffLines(diff)

        let context = lines.first { $0.raw == " let same = true" }
        #expect(context?.kind == .context)
        #expect(context?.oldLineNumber == 10)
        #expect(context?.newLineNumber == 10)
        #expect(context?.reviewLineNumber == 10)
        #expect(context?.reviewSide == .context)
        #expect(context?.code == "let same = true")

        let deletion = lines.first { $0.raw == "-oldCall()" }
        #expect(deletion?.kind == .deletion)
        #expect(deletion?.oldLineNumber == 11)
        #expect(deletion?.newLineNumber == nil)
        #expect(deletion?.reviewLineNumber == 11)
        #expect(deletion?.reviewSide == .old)

        let firstAddition = lines.first { $0.raw == "+newCall()" }
        #expect(firstAddition?.kind == .addition)
        #expect(firstAddition?.oldLineNumber == nil)
        #expect(firstAddition?.newLineNumber == 11)
        #expect(firstAddition?.reviewLineNumber == 11)
        #expect(firstAddition?.reviewSide == .new)

        let secondAddition = lines.first { $0.raw == "+addedCall()" }
        #expect(secondAddition?.newLineNumber == 12)
    }

    @Test
    func skillAutocompleteContextUsesTrailingSlashToken() {
        let draft = "Please run /ios"
        let context = SkillAutocompleteContext(draft: draft, selection: nil)

        #expect(context?.query == "ios")
        #expect(context?.invocationPrefix == "/")
        #expect(context?.signature == "11:/ios")
        if let range = context?.range {
            #expect(String(draft[range]) == "/ios")
        }
    }

    @Test
    func skillAutocompleteContextUsesTrailingDollarToken() {
        let draft = "Please run $ios"
        let context = SkillAutocompleteContext(draft: draft, selection: nil)

        #expect(context?.query == "ios")
        #expect(context?.invocationPrefix == "$")
        #expect(context?.signature == "11:$ios")
        if let range = context?.range {
            #expect(String(draft[range]) == "$ios")
        }
    }

    @Test
    func skillAutocompleteContextIgnoresNonTriggerTokens() {
        #expect(SkillAutocompleteContext(draft: "Please run ios", selection: nil) == nil)
        #expect(SkillAutocompleteContext(draft: "Please run /ios now", selection: nil) == nil)
        #expect(SkillAutocompleteContext(draft: "Please run $ios now", selection: nil) == nil)
    }

    @Test
    func harnessKeyRowsExposeExtendedTerminalControls() {
        #expect(HarnessKey.inputRows == [
            [.up, .down, .tab, .enter],
            [.left, .right, .escape, .backspace],
        ])
        #expect(HarnessKey.backspace.rawValue == "backspace")
        #expect(HarnessKey.backspace.label == "Bkspc")
        #expect(HarnessKey.escape.label == "Esc")
        #expect(HarnessKey.escape.systemImage == "x.square")
    }
}
