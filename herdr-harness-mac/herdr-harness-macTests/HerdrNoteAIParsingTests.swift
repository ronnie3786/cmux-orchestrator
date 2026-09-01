import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr note AI parsing")
struct HerdrNoteAIParsingTests {
    @Test("fenceSafe defuses embedded fence-like lines and stays balanced")
    func fenceSafeDefusesDelimiters() {
        let note = "before\n<<< sneaky\nmiddle\n>>> also sneaky\nafter"
        let safe = HerdrNoteAIParsing.fenceSafe(note)
        #expect(!safe.contains("\n<<<"))
        #expect(!safe.contains("\n>>>"))
        #expect(safe.hasPrefix("before"))
        let wrapped = "<<<NOTE\n\(safe)\nNOTE>>>"
        #expect(wrapped.components(separatedBy: "<<<NOTE").count == 2)
        #expect(wrapped.components(separatedBy: "NOTE>>>").count == 2)
    }
    @Test("Strip fence unwraps one fenced block and trims unfenced text")
    func stripFence() {
        #expect(HerdrNoteAIParsing.stripFence("\n```json\n{\"ok\":true}\n```\n") == "{\"ok\":true}")
        #expect(HerdrNoteAIParsing.stripFence("\n plain text \n") == "plain text")
    }

    @Test("Cleanup extracts hash and separated titles")
    func cleanupTitles() throws {
        let heading = try #require(HerdrNoteAIParsing.cleanup("# Title\n\nbody line"))
        #expect(heading.title == "Title")
        #expect(heading.body == "body line")

        let separated = try #require(HerdrNoteAIParsing.cleanup("Short title\n\nrest of body"))
        #expect(separated.title == "Short title")
        #expect(separated.body == "rest of body")
    }

    @Test("Cleanup leaves non-title opening text in the body")
    func cleanupNoTitle() throws {
        let longLine = String(repeating: "a", count: 81)
        let longResult = try #require(HerdrNoteAIParsing.cleanup("\(longLine)\n\nbody"))
        #expect(longResult.title == nil)
        #expect(longResult.body == "\(longLine)\n\nbody")

        let noSeparator = try #require(HerdrNoteAIParsing.cleanup("First line\nsecond line"))
        #expect(noSeparator.title == nil)
        #expect(noSeparator.body == "First line\nsecond line")
    }

    @Test("Cleanup normalizes bullets and checkboxes")
    func cleanupBullets() throws {
        let result = try #require(HerdrNoteAIParsing.cleanup("- item\n* item\n- [ ] task\n- [x] done"))
        #expect(result.body == "• item\n• item\n☐ task\n☑ done")
    }

    @Test("Cleanup caps consecutive blank lines and rejects blank input")
    func cleanupBlankLines() throws {
        let result = try #require(HerdrNoteAIParsing.cleanup("line one\nsome content\n\n\n\nmore text"))
        #expect(result.title == nil)
        #expect(result.body == "line one\nsome content\n\n\nmore text")
        #expect(HerdrNoteAIParsing.cleanup(" \n\t ") == nil)
    }

    @Test("Smart actions parses fenced JSON and bounds strings")
    func smartActionsParsesJSON() throws {
        let longTitle = String(repeating: "t", count: 70)
        let longPrompt = String(repeating: "p", count: 4_100)
        let response = "preamble\n```json\n{\"summary\": \"  Summary  \", \"actions\": [{\"title\": \"  \(longTitle)  \", \"prompt\": \"  \(longPrompt)  \"}, {\"title\": \"Second\", \"prompt\": \"Do it\"}]}\n```\ntrailing"
        let parsed = try #require(HerdrNoteAIParsing.smartActions(response))
        #expect(parsed.summary == "Summary")
        #expect(parsed.actions.count == 2)
        #expect(parsed.actions[0].title.count == 60)
        #expect(parsed.actions[0].prompt.count == 4_000)
        #expect(parsed.actions[1] == .init(title: "Second", prompt: "Do it"))
    }

    @Test("Smart actions keeps at most four valid actions")
    func smartActionsCapsActions() throws {
        let actions = (0..<6).map { "{\"title\":\"Action \($0)\",\"prompt\":\"Prompt \($0)\"}" }.joined(separator: ",")
        let parsed = try #require(HerdrNoteAIParsing.smartActions("{\"actions\":[\(actions)]}"))
        #expect(parsed.actions.map(\.title) == ["Action 0", "Action 1", "Action 2", "Action 3"])
    }

    @Test("Smart actions drops invalid actions but preserves valid siblings")
    func smartActionsDropsInvalidActions() throws {
        let parsed = try #require(HerdrNoteAIParsing.smartActions(#"""
        {"actions":[
          {"title":"Valid","prompt":"Complete it"},
          {"title":"","prompt":"Nope"},
          {"title":"No prompt"},
          {"title":"Also valid","prompt":"Continue"}
        ]}
        """#))
        #expect(parsed.actions == [
            .init(title: "Valid", prompt: "Complete it"),
            .init(title: "Also valid", prompt: "Continue"),
        ])
    }

    @Test("Smart actions requires JSON but allows an empty actions array")
    func smartActionsEmptyArray() throws {
        #expect(HerdrNoteAIParsing.smartActions("No object here") == nil)
        let parsed = try #require(HerdrNoteAIParsing.smartActions("{\"actions\":[]}"))
        #expect(parsed.summary == nil)
        #expect(parsed.actions.isEmpty)
    }
}
