import Testing
@testable import herdr_harness_mac

@Suite("Pi markdown streaming split")
struct PiMarkdownStreamingSplitTests {
    @Test("Leaves a single growing paragraph entirely in the tail")
    func leavesSingleParagraphInTail() {
        let source = "A growing response with no completed paragraph yet"
        #expect(PiMarkdownParser.splitStreamingTail(source) == .init(prefix: "", tail: source))
    }

    @Test("Uses the last completed blank-line boundary")
    func usesLastBlankLineBoundary() {
        let source = "First paragraph\n\nSecond paragraph\nstill growing"
        #expect(
            PiMarkdownParser.splitStreamingTail(source)
                == .init(prefix: "First paragraph", tail: "Second paragraph\nstill growing")
        )
    }

    @Test("Keeps an unfinished fence wholly in the tail after a safe boundary")
    func keepsUnfinishedFenceInTail() {
        let source = "Finished prose\n\n```swift\nlet value = 42\n\nstill in the fence"
        let split = PiMarkdownParser.splitStreamingTail(source)

        #expect(split.prefix == "Finished prose")
        #expect(split.tail == "```swift\nlet value = 42\n\nstill in the fence")
        #expect(!split.prefix.contains("```swift"))
        #expect(split.tail.contains("```swift"))
    }

    @Test("Leaves an unfinished fence in the tail when no safe boundary exists")
    func leavesUnfinishedFenceWithoutBoundaryInTail() {
        let source = "```sh\necho ready\n\nstill streaming"
        #expect(PiMarkdownParser.splitStreamingTail(source) == .init(prefix: "", tail: source))
    }

    @Test("Can split after a closed fence")
    func splitsAfterClosedFence() {
        let source = "Intro\n```swift\nlet value = 42\n```\n\nTrailing prose"
        #expect(
            PiMarkdownParser.splitStreamingTail(source)
                == .init(prefix: "Intro\n```swift\nlet value = 42\n```", tail: "Trailing prose")
        )
    }

    @Test("Does not split single newlines")
    func doesNotSplitSoftBreaks() {
        let source = "one\ntwo\nthree"
        #expect(PiMarkdownParser.splitStreamingTail(source) == .init(prefix: "", tail: source))
    }

    @Test("Preserves visible content when blank separator whitespace is restored")
    func preservesVisibleContent() {
        let source = "First paragraph\n\n\nSecond paragraph"
        let split = PiMarkdownParser.splitStreamingTail(source)
        let reassembled = split.prefix + "\n\n" + split.tail

        #expect(nonWhitespaceCharacters(in: reassembled) == nonWhitespaceCharacters(in: source))
    }

    private func nonWhitespaceCharacters(in source: String) -> String {
        var result = ""
        for character in source where !character.isWhitespace {
            result.append(character)
        }
        return result
    }
}
