import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Cleanup report decoding")
struct CleanupReportDecodingTests {
    @Test("Full report preserves the cleanup wire contract")
    func fullReport() throws {
        let report = try JSONDecoder().decode(CleanupRunEnvelope.self, from: Data(fullFixture.utf8))

        #expect(report.ok)
        #expect(report.run.runID == "clr_1a2b3c4d5e6f")
        #expect(report.run.status == .done)
        #expect(report.run.config?.thinkingLevel == .medium)
        #expect(report.run.judge?.durationMs == 83_210)
        #expect(report.workspaces?.first?.panes.first?.agentStatus == .done)
        #expect(report.workspaces?.first?.panes.first?.classification == .completed)
        #expect(report.workspaces?.first?.panes.first?.costUSD == 3.41)
        #expect(CleanupRail.label(for: "R2:focused") == "currently focused pane")
        #expect(CleanupRail.label(for: "future:rail") == "future:rail")
        #expect(CleanupClassification.completed.symbol == "checkmark.circle.fill")
        #expect(CleanupClassification.needsHuman.label == "Needs you")
    }

    @Test("Unknown classifications and real collecting payloads remain decodable")
    func forwardCompatibility() throws {
        let collecting = try JSONDecoder().decode(CleanupRunEnvelope.self, from: Data(collectingFixture.utf8))
        #expect(collecting.run.status == .collecting)
        #expect(collecting.run.phase == .collecting)
        #expect(collecting.run.progress?.done == 2)
        #expect(collecting.run.phaseHistory.count == 1)
        #expect(collecting.run.config?.model == "custom-lux-dspark/qwen3.8-27b-nvfp4-dspark")
        #expect(collecting.workspaces == nil)
        #expect(collecting.summary == nil)

        let report = try JSONDecoder().decode(CleanupRunEnvelope.self, from: Data(fullFixture.replacingOccurrences(of: "\"completed\"", with: "\"future_value\"").utf8))
        #expect(report.workspaces?.first?.panes.first?.classification == .unknown)
        #expect(report.workspaces?.first?.panes.first?.blockedBy == ["R2:focused", "future:rail"])

        let unknownThinkingRun = try JSONDecoder().decode(
            CleanupRunEnvelope.self,
            from: Data(fullFixture.replacingOccurrences(of: "\"thinkingLevel\":\"medium\"", with: "\"thinkingLevel\":\"ludicrous\"").utf8)
        )
        #expect(unknownThinkingRun.run.config?.thinkingLevel == .medium)

        let unknownThinkingDefault = try JSONDecoder().decode(
            CleanupModelCatalog.self,
            from: Data(modelCatalogFixture.replacingOccurrences(of: "\"thinkingLevel\":\"medium\"", with: "\"thinkingLevel\":\"ludicrous\"").utf8)
        )
        #expect(unknownThinkingDefault.defaultModel?.thinkingLevel == .medium)
    }

    @Test("Real terminal payload merges flat lifecycle fields with nested report run")
    func terminalPayload() throws {
        let report = try JSONDecoder().decode(CleanupRunEnvelope.self, from: Data(terminalFixture.utf8))

        #expect(report.run.judge?.durationMs == 83_210)
        #expect(report.run.phaseHistory.count == 3)
        #expect(report.run.phase == .done)
        #expect(report.workspaces?.count == 1)
        #expect(report.summary?.panesScanned == 2)
    }

    @Test("Null report fields are tolerated")
    func nullFields() throws {
        let report = try JSONDecoder().decode(CleanupRunEnvelope.self, from: Data(nullFixture.utf8))
        let workspace = try #require(report.workspaces?.first)
        let pane = try #require(workspace.panes.first)

        #expect(workspace.label == nil)
        #expect(pane.title == nil)
        #expect(pane.agentStatus == .unknown)
        #expect(report.run.config?.model == nil)
    }

    @Test("Model catalog accepts omitted display fields and empty server defaults")
    func modelCatalog() throws {
        let catalog = try JSONDecoder().decode(CleanupModelCatalog.self, from: Data(modelCatalogFixture.utf8))

        #expect(catalog.models.first?.displayName == "qwen3.8-27b-nvfp4-dspark")
        #expect(catalog.defaultModel?.fullID == nil)
    }

    private let fullFixture = #"""
    {"ok":true,"run":{"runId":"clr_1a2b3c4d5e6f","status":"done","phase":"done","phaseDetail":"Ready","progress":{"done":4,"total":4},"phaseHistory":[{"phase":"collecting","startedAt":"2026-08-21T20:04:11Z","finishedAt":"2026-08-21T20:04:15Z","detail":"Captured"}],"startedAt":"2026-08-21T20:04:11Z","finishedAt":"2026-08-21T20:06:02Z","session":"default","config":{"model":"custom-lux-dspark/qwen3.8-27b-nvfp4-dspark","thinkingLevel":"medium","costThresholdUSD":2.0,"tailLines":400,"minConfidence":0.6},"judge":{"batches":4,"failedBatches":0,"costUSD":0.031,"durationMs":83210},"error":null},"workspaces":[{"workspaceId":"w3","label":"fix-login-flake","workspaceCloseRecommended":true,"workspaceSafeToClose":true,"workspaceBlockedBy":[],"git":{"state":"clean"},"panes":[{"paneId":"w3:p1","title":"pi · fix-login-flake","agentKind":"pi","agentStatus":"done","classification":"completed","confidence":0.92,"reason":"Done.","closeRecommended":true,"safeToClose":true,"blockedBy":["R2:focused","future:rail"],"costUSD":3.41,"costSource":"sessionFile","costOverThreshold":true,"signals":{"doneAlertAgeSeconds":21600,"revisionChanged":false,"sessionFileAgeSeconds":22110,"starred":false,"focused":false,"unreadAlerts":0}}]}],"summary":{"panesScanned":14,"closeCandidates":6,"railBlocked":2,"costFlags":[{"paneId":"w3:p1","costUSD":3.41}],"totalKnownCostUSD":5.87,"unknownCostPanes":3}}
    """#

    private let collectingFixture = #"""
    {"ok":true,"runId":"clr_1a2b3c4d5e6f","status":"collecting","startedAt":"2026-08-21T20:04:11Z","finishedAt":null,"session":"default","config":{"model":"custom-lux-dspark/qwen3.8-27b-nvfp4-dspark","thinkingLevel":"medium","costThresholdUSD":2.0,"tailLines":400,"minConfidence":0.6},"workspaceIds":[],"keepEvidence":false,"error":null,"phase":"collecting","phaseDetail":"Capturing pane pi · fix-login-flake (2 of 7)","progress":{"done":2,"total":7},"phaseHistory":[{"phase":"collecting","startedAt":"2026-08-21T20:04:11Z","finishedAt":null,"detail":null}]}
    """#

    private let terminalFixture = #"""
    {"ok":true,"runId":"clr_1a2b3c4d5e6f","status":"done","startedAt":"2026-08-21T20:04:11Z","finishedAt":"2026-08-21T20:06:02Z","session":"default","config":{"model":"custom-lux-dspark/qwen3.8-27b-nvfp4-dspark","thinkingLevel":"medium","costThresholdUSD":2.0,"tailLines":400,"minConfidence":0.6},"workspaceIds":[],"keepEvidence":false,"error":null,"phase":"done","phaseDetail":"Cleanup report ready","progress":{"done":2,"total":2},"phaseHistory":[{"phase":"collecting","startedAt":"2026-08-21T20:04:11Z","finishedAt":"2026-08-21T20:04:15Z","detail":"Captured 2 panes"},{"phase":"judging","startedAt":"2026-08-21T20:04:15Z","finishedAt":"2026-08-21T20:05:38Z","detail":"Reviewed 1 workspace batch"},{"phase":"gating","startedAt":"2026-08-21T20:05:38Z","finishedAt":"2026-08-21T20:06:02Z","detail":"Applied safety rails"}],"workspaces":[{"workspaceId":"w3","label":"fix-login-flake","workspaceCloseRecommended":false,"workspaceSafeToClose":false,"workspaceBlockedBy":[],"git":{"state":"clean"},"panes":[]}],"summary":{"panesScanned":2,"closeCandidates":1,"railBlocked":1,"costFlags":[],"totalKnownCostUSD":0.0,"unknownCostPanes":2},"run":{"runId":"clr_1a2b3c4d5e6f","status":"done","startedAt":"2026-08-21T20:04:11Z","finishedAt":"2026-08-21T20:06:02Z","session":"default","config":{"model":"custom-lux-dspark/qwen3.8-27b-nvfp4-dspark","thinkingLevel":"medium","costThresholdUSD":2.0,"tailLines":400,"minConfidence":0.6},"judge":{"batches":2,"failedBatches":0,"costUSD":0.031,"durationMs":83210},"error":null}}
    """#

    private let nullFixture = #"""
    {"ok":true,"run":{"runId":"clr_nulls","status":"done","config":{"model":null,"thinkingLevel":"future_level","costThresholdUSD":2.0},"judge":{"batches":1,"failedBatches":0,"costUSD":0.0,"durationMs":1},"error":null},"workspaces":[{"workspaceId":"w1","label":null,"workspaceCloseRecommended":false,"workspaceSafeToClose":false,"workspaceBlockedBy":[],"git":{"state":"clean"},"panes":[{"paneId":"w1:p1","title":null,"agentKind":"pi","agentStatus":null,"classification":"completed","confidence":0.9,"reason":"Done.","closeRecommended":false,"safeToClose":false,"blockedBy":[],"costUSD":null,"costSource":null,"costOverThreshold":false,"signals":null}]}]}
    """#

    private let modelCatalogFixture = #"""
    {"ok":true,"models":[{"provider":"custom-lux-dspark","id":"qwen3.8-27b-nvfp4-dspark"}],"default":{"provider":null,"id":null,"thinkingLevel":"medium"}}
    """#
}
