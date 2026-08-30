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
    }

    @Test("Rejects malformed board bridge messages")
    func malformedMessages() {
        #expect(ActiveWorkBoardMessage.parse(["type": "bogus"]) == nil)
        #expect(ActiveWorkBoardMessage.parse([:]) == nil)
        #expect(ActiveWorkBoardMessage.parse(["type": "openPane"]) == nil)
        #expect(ActiveWorkBoardMessage.parse(["type": "openExternal"]) == nil)
        #expect(ActiveWorkBoardMessage.parse(["type": "copy"]) == nil)
        #expect(ActiveWorkBoardMessage.parse(["type": 42]) == nil)
    }
}
