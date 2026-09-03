import Foundation
import Testing
@testable import herdr_harness_mac

struct ActiveWorkBoardMessageTests {
    @Test("Parses valid board bridge messages")
    func validMessages() {
        #expect(
            ActiveWorkBoardMessage.parse(["type": "openPane", "paneId": "p1", "machineId": "m1"])
                == .openPane(paneId: "p1", machineId: "m1")
        )
        #expect(
            ActiveWorkBoardMessage.parse(["type": "openPane", "paneId": "p1"])
                == .openPane(paneId: "p1", machineId: nil)
        )
        #expect(
            ActiveWorkBoardMessage.parse(["type": "openPane", "paneId": "p1", "machineId": NSNull()])
                == .openPane(paneId: "p1", machineId: nil)
        )
        #expect(
            ActiveWorkBoardMessage.parse(["type": "openExternal", "url": "https://example.test"])
                == .openExternal(url: "https://example.test")
        )
        #expect(
            ActiveWorkBoardMessage.parse(["type": "copy", "text": "some text"])
                == .copy(text: "some text")
        )
        #expect(ActiveWorkBoardMessage.parse(["type": "popout"]) == .popout)
        #expect(
            ActiveWorkBoardMessage.parse([
                "type": "spawnReview",
                "workId": "pr-watch-doximity-ios-doximity-11918",
                "stageKey": "ios-review",
                "skill": "ios-review-remote-pr",
                "prUrl": "https://github.com/doximity/iOS-Doximity/pull/11918",
                "prNumber": 11918,
                "title": "PR #11918 · Fix notifications",
                "customText": "",
            ])
                == .spawnReview(
                    ActiveWorkSpawnReviewPayload(
                        workID: "pr-watch-doximity-ios-doximity-11918",
                        stageKey: "ios-review",
                        skill: "ios-review-remote-pr",
                        prURL: "https://github.com/doximity/iOS-Doximity/pull/11918",
                        prNumber: 11918,
                        title: "PR #11918 · Fix notifications",
                        customText: ""
                    )
                )
        )
        #expect(
            ActiveWorkBoardMessage.parse([
                "type": "spawnReview",
                "workId": "w1",
                "stageKey": "custom-review",
                "skill": "custom-review",
                "customText": "Check the error handling only",
            ])
                == .spawnReview(
                    ActiveWorkSpawnReviewPayload(
                        workID: "w1",
                        stageKey: "custom-review",
                        skill: "custom-review",
                        prURL: "",
                        prNumber: nil,
                        title: "",
                        customText: "Check the error handling only"
                    )
                )
        )
    }

    @Test("Rejects malformed board bridge messages")
    func malformedMessages() {
        #expect(ActiveWorkBoardMessage.parse(["type": "bogus"]) == nil)
        #expect(ActiveWorkBoardMessage.parse([:]) == nil)
        #expect(ActiveWorkBoardMessage.parse(["type": "openPane"]) == nil)
        #expect(ActiveWorkBoardMessage.parse(["type": "openExternal"]) == nil)
        #expect(ActiveWorkBoardMessage.parse(["type": "copy"]) == nil)
        #expect(ActiveWorkBoardMessage.parse(["type": 42]) == nil)
        #expect(ActiveWorkBoardMessage.parse(["type": "spawnReview", "stageKey": "ios-review", "skill": "x"]) == nil)
        #expect(ActiveWorkBoardMessage.parse(["type": "spawnReview", "workId": "w1", "skill": "x"]) == nil)
        #expect(ActiveWorkBoardMessage.parse(["type": "spawnReview", "workId": "w1", "stageKey": "ios-review"]) == nil)
    }
}
