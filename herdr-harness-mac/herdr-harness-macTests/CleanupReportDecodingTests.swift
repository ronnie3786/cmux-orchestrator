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
        #expect(report.workspaces?.first?.title == nil)
        #expect(report.workspaces?.first?.panes.first?.evidenceCited == [])
        #expect(report.workspaces?.first?.panes.first?.piSession == nil)
        #expect(report.summary?.workspaceTitles == nil)
        #expect(report.applyResult == nil)
        #expect(CleanupRail.label(for: "R2:focused") == "currently focused pane")
        #expect(CleanupRail.label(for: "future:rail") == "future:rail")
        #expect(CleanupClassification.completed.symbol == "checkmark.circle.fill")
        #expect(CleanupClassification.needsHuman.label == "Needs you")
    }

    @Test("Enhanced reports decode workspace, activity, usage, and Pi-session insights")
    func enhancedReport() throws {
        let report = try JSONDecoder().decode(CleanupRunEnvelope.self, from: Data(enhancedFixture.utf8))
        let workspace = try #require(report.workspaces?.first)
        let pane = try #require(workspace.panes.first)
        let summary = try #require(report.summary)

        #expect(workspace.title == "Fix Login Flake")
        #expect(workspace.workspaceReason == "Keep while tests finish.")
        #expect(workspace.summary == "The fix is merged, but tests are active.")
        #expect(pane.summary == "Implemented and merged the retry fix.")
        #expect(pane.activitySummary == "Pi is connected and idle.")
        #expect(pane.usageSummary == "Pi session retry is connected; $3.41 used.")
        #expect(pane.evidenceCited == ["transcript.md: PR merged", "signal:agentStatus=done"])
        #expect(pane.piSession?.sessionID == "pi_retry_8421")
        #expect(pane.piSession?.active == true)
        #expect(pane.piSession?.idle == true)
        #expect(pane.piSession?.totalTokens == 186_420)
        #expect(pane.signals?.agentStatus == .done)
        #expect(pane.signals?.piActive == true)
        #expect(pane.signals?.looksLikeIdleAgentTUI == true)
        #expect(pane.signals?.tailTruncated == false)
        #expect(summary.workspacesScanned == 1)
        #expect(summary.workspaceTitles == ["Fix Login Flake"])
        #expect(summary.workspaceSummaries?.first?.activePiSessions == 1)
        #expect(summary.classifications?["completed"] == 1)
        #expect(summary.activePiSessions == 1)
        #expect(summary.knownCostPanes == 1)
    }

    @Test("Legacy and enhanced apply responses both decode")
    func applyWireCompatibility() throws {
        let legacy = try JSONDecoder().decode(CleanupApplyResponse.self, from: Data(legacyApplyFixture.utf8))
        #expect(legacy.applied.panes == ["w3:p1"])
        #expect(legacy.piSessions == nil)
        #expect(legacy.ledger == nil)
        #expect(legacy.deduplicatedPaneIDs == nil)
        #expect(legacy.complete == nil)
        #expect(legacy.error == nil)

        let enhanced = try JSONDecoder().decode(CleanupApplyResponse.self, from: Data(enhancedApplyFixture.utf8))
        let result = try #require(enhanced.piSessions?.results.first)
        let record = try #require(enhanced.ledger?.records.first)

        #expect(enhanced.piSessions?.ended == 1)
        #expect(enhanced.piSessions?.failed == 0)
        #expect(result.paneID == "w3:p1")
        #expect(result.sessionID == "pi_retry_8421")
        #expect(result.quitSucceeded)
        #expect(result.closeOutcome == "closed")
        #expect(enhanced.ledger?.recordsAppended == 1)
        #expect(record.cleanupRunID == "clr_1a2b3c4d5e6f")
        #expect(record.workspace.title == "Fix Login Flake")
        #expect(record.pane.tabID == "tab-3")
        #expect(record.piSession.sessionID == "pi_retry_8421")
        #expect(record.quit.outcome == "ended")
        #expect(record.close.scope == "pane")
        #expect(enhanced.deduplicatedPaneIDs == ["w3:p2"])
        #expect(enhanced.complete == true)
        #expect(enhanced.error == nil)
    }

    @Test("Failed async apply GET preserves confirmed partial outcomes")
    func failedAsyncApplyResult() throws {
        let envelope = try JSONDecoder().decode(CleanupRunEnvelope.self, from: Data(failedApplyFixture.utf8))
        let result = try #require(envelope.applyResult)

        #expect(envelope.run.status == .failed)
        #expect(result.complete == false)
        #expect(result.error == "Fresh workspace snapshot failed")
        #expect(result.applied.panes == ["w3:p1"])
        #expect(result.skipped.first?.id == "w3:p2")
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

    @Test("Applying GET payload decodes as an active nonterminal phase")
    func applyingWireState() throws {
        let envelope = try JSONDecoder().decode(CleanupRunEnvelope.self, from: Data(applyingFixture.utf8))

        #expect(envelope.run.status == .applying)
        #expect(envelope.run.phase == .applying)
        #expect(envelope.run.phaseHistory.last?.phase == .applying)
        #expect(envelope.run.phaseDetail == "Revalidating selected panes and workspaces")
        #expect(envelope.run.status.isTerminal == false)
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

    @Test("Fractional pane signal ages decode without corrupting the envelope")
    func fractionalSignalAges() throws {
        let report = try JSONDecoder().decode(CleanupRunEnvelope.self, from: Data(fractionalSignalsFixture.utf8))
        let pane = try #require(report.workspaces?.first?.panes.first)

        #expect(pane.signals?.doneAlertAgeSeconds == 369398.1364490986)
        #expect(pane.signals?.sessionFileAgeSeconds == 529216.9183209419)
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

    private let applyingFixture = #"""
    {"ok":true,"run":{"runId":"clr_applying","status":"applying","phase":"applying","phaseDetail":"Revalidating selected panes and workspaces","progress":{"done":1,"total":3},"phaseHistory":[{"phase":"collecting","startedAt":"2026-08-21T20:04:11Z","finishedAt":"2026-08-21T20:04:15Z","detail":"Captured"},{"phase":"judging","startedAt":"2026-08-21T20:04:15Z","finishedAt":"2026-08-21T20:05:38Z","detail":"Judged"},{"phase":"gating","startedAt":"2026-08-21T20:05:38Z","finishedAt":"2026-08-21T20:06:02Z","detail":"Checked safety rails"},{"phase":"applying","startedAt":"2026-08-21T20:06:12Z","finishedAt":null,"detail":null}],"startedAt":"2026-08-21T20:04:11Z","finishedAt":null,"session":"default","config":{"model":"test","thinkingLevel":"medium","costThresholdUSD":2.0},"judge":{"batches":2,"failedBatches":0,"costUSD":0.031,"durationMs":83210},"error":null},"workspaces":[],"summary":{"panesScanned":0,"closeCandidates":0,"railBlocked":0,"costFlags":[],"totalKnownCostUSD":0.0,"unknownCostPanes":0}}
    """#

    private let enhancedFixture = #"""
    {"ok":true,"run":{"runId":"clr_enhanced","status":"done","phase":"done","config":{"model":"test","thinkingLevel":"medium","costThresholdUSD":2.0},"judge":{"batches":1,"failedBatches":0,"costUSD":0.01,"durationMs":1200}},"workspaces":[{"workspaceId":"w3","label":"fix-login-flake","title":"Fix Login Flake","workspaceReason":"Keep while tests finish.","summary":"The fix is merged, but tests are active.","workspaceCloseRecommended":false,"workspaceSafeToClose":false,"workspaceBlockedBy":["R6:pane_blocked"],"git":{"state":"clean"},"panes":[{"paneId":"w3:p1","title":"pi · fix-login-flake","agentKind":"pi","agentStatus":"done","classification":"completed","confidence":0.92,"summary":"Implemented and merged the retry fix.","reason":"The transcript says the PR merged.","evidenceCited":["transcript.md: PR merged","signal:agentStatus=done"],"activitySummary":"Pi is connected and idle.","usageSummary":"Pi session retry is connected; $3.41 used.","closeRecommended":true,"safeToClose":true,"blockedBy":[],"costUSD":3.41,"costSource":"sessionFile","costOverThreshold":true,"piSession":{"detected":true,"sessionId":"pi_retry_8421","sessionFile":"/tmp/pi_retry_8421.jsonl","sessionName":"retry","cwd":"/work/fix-login-flake","connected":true,"active":true,"idle":true,"costUSD":3.41,"totalTokens":186420},"signals":{"agentStatus":"done","doneAlertAgeSeconds":21600,"blockedAlertAgeSeconds":null,"revisionChanged":false,"sessionFileAgeSeconds":22110,"piStateAgeSeconds":21580,"starred":false,"focused":false,"unreadAlerts":0,"piConnected":true,"piActive":true,"piWorking":false,"endsAtShellPrompt":false,"hasProcessExitedMarker":false,"looksLikeIdleAgentTui":true,"tailIsEmpty":false,"tailTruncated":false}}]}],"summary":{"panesScanned":1,"closeCandidates":1,"railBlocked":0,"costFlags":[{"paneId":"w3:p1","costUSD":3.41}],"totalKnownCostUSD":3.41,"unknownCostPanes":0,"workspacesScanned":1,"workspaceCloseCandidates":0,"workspaceTitles":["Fix Login Flake"],"workspaceSummaries":[{"workspaceId":"w3","title":"Fix Login Flake","summary":"The fix is merged, but tests are active.","workspaceReason":"Keep while tests finish.","paneCount":1,"closeCandidates":1,"railBlocked":0,"activePanes":0,"piPanes":1,"activePiSessions":1}],"classifications":{"completed":1,"stale":0,"active":0,"blocked":0,"needs_human":0,"unknown":0},"activePanes":0,"blockedPanes":0,"piPanes":1,"activePiSessions":1,"knownCostPanes":1}}
    """#

    private let legacyApplyFixture = #"""
    {"ok":true,"applied":{"panes":["w3:p1"],"workspaces":[]},"skipped":[]}
    """#

    private let enhancedApplyFixture = #"""
    {"ok":true,"complete":true,"applied":{"panes":["w3:p1"],"workspaces":[]},"skipped":[],"piSessions":{"ended":1,"failed":0,"results":[{"paneId":"w3:p1","sessionId":"pi_retry_8421","wasActive":true,"quitAttempted":true,"quitSucceeded":true,"closeOutcome":"closed","reason":null}]},"ledger":{"path":"/tmp/pane-session-ledger.jsonl","recordsAppended":1,"records":[{"cleanupRunId":"clr_1a2b3c4d5e6f","timestamp":"2026-08-21T20:06:12Z","workspace":{"id":"w3","title":"Fix Login Flake"},"pane":{"id":"w3:p1","title":"pi · fix-login-flake","tabId":"tab-3","cwd":"/work/fix-login-flake"},"piSession":{"detected":true,"sessionId":"pi_retry_8421","sessionFile":"/tmp/pi_retry_8421.jsonl","sessionName":"retry","cwd":"/work/fix-login-flake","connected":true,"active":true,"idle":true,"costUSD":3.41,"totalTokens":186420},"quit":{"attempted":true,"succeeded":true,"outcome":"ended","error":null},"close":{"scope":"pane","outcome":"closed","error":null}}]},"deduplicatedPaneIds":["w3:p2"]}
    """#

    private let failedApplyFixture = #"""
    {"ok":true,"run":{"runId":"clr_async_apply","status":"failed","phase":"failed","phaseDetail":"Cleanup apply stopped after partial progress","error":"Fresh workspace snapshot failed"},"applyResult":{"ok":false,"complete":false,"applied":{"panes":["w3:p1"],"workspaces":[]},"skipped":[{"id":"w3:p2","reason":"R8:state_changed"}],"error":"Fresh workspace snapshot failed"}}
    """#

    private let fractionalSignalsFixture = #"""
    {"ok":true,"run":{"runId":"clr_fractional","status":"done","phase":"done","progress":{"done":1,"total":1},"config":{"model":"test","thinkingLevel":"medium","costThresholdUSD":2.0},"judge":{"batches":1,"failedBatches":0,"costUSD":0.0,"durationMs":1}},"workspaces":[{"workspaceId":"w1","workspaceCloseRecommended":false,"workspaceSafeToClose":false,"workspaceBlockedBy":[],"git":{"state":"clean"},"panes":[{"paneId":"w1:p1","agentKind":"pi","agentStatus":"done","classification":"completed","confidence":0.9,"reason":"Done.","closeRecommended":true,"safeToClose":true,"blockedBy":[],"costOverThreshold":false,"signals":{"doneAlertAgeSeconds":369398.1364490986,"revisionChanged":false,"sessionFileAgeSeconds":529216.9183209419,"starred":false,"focused":true,"unreadAlerts":0}}]}]}
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
