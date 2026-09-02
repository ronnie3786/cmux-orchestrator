import Foundation
import Testing
@testable import herdr_harness_ios

struct HerdrAPIClientTimeoutTests {
    @Test func proxiedToolRequestsOutliveCmuxOperations() {
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/workspaces/w1/git", method: "GET") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/workspaces/w1/git/stage", method: "POST") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/workspaces/w1/skills", method: "GET") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/workspaces/w1/files", method: "GET") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/jira/assigned", method: "GET") == 30)
    }

    @Test func uploadsAndStreamsKeepTheirLongerBudgets() {
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/workspaces/w1/attachments", method: "POST") == 90)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/voice/transcriptions", method: "POST") == 120)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/response-audio/capabilities", method: "GET") == 8)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/response-audio/prepare", method: "POST") == 150)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/response-audio/speech", method: "POST") == 150)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/panes/p1/stream", method: "GET") == 24 * 60 * 60)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/events", method: "GET") == 24 * 60 * 60)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/agent-runs", method: "POST") == 90)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/agent-runs/run-1", method: "GET") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/agent-runs/run-1/promote", method: "POST") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/agent-runs/models", method: "GET") == 30)
        #expect(HerdrAPIClient.timeoutInterval(path: "/api/v1/workspaces", method: "GET") == 15)
    }
}
