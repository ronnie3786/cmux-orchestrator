import Foundation
import SwiftUI

enum CleanupRunStatus: String, Codable, Sendable, Equatable {
    case collecting
    case judging
    case gating
    case applying
    case done
    case failed
    case applied
    case partial
    case unknown

    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    var isTerminal: Bool {
        switch self {
        case .done, .failed, .applied, .partial: true
        case .collecting, .judging, .gating, .applying, .unknown: false
        }
    }
}

enum CleanupPhase: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case collecting
    case judging
    case gating
    case applying
    case done
    case failed

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed
    }

    var label: String {
        switch self {
        case .collecting: "Capture pane content"
        case .judging: "AI judge review"
        case .gating: "Safety checks"
        case .applying: "End sessions and close"
        case .done: "Report"
        case .failed: "Cleanup stopped"
        }
    }
}

struct CleanupRunEnvelope: Codable, Sendable, Equatable {
    let ok: Bool
    let run: CleanupRun
    let workspaces: [CleanupWorkspaceReport]?
    let summary: CleanupSummary?
    let applyResult: CleanupApplyResponse?

    enum CodingKeys: String, CodingKey {
        case ok, run, workspaces, summary, applyResult
    }

    init(
        ok: Bool,
        run: CleanupRun,
        workspaces: [CleanupWorkspaceReport]?,
        summary: CleanupSummary?,
        applyResult: CleanupApplyResponse? = nil
    ) {
        self.ok = ok
        self.run = run
        self.workspaces = workspaces
        self.summary = summary
        self.applyResult = applyResult
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        run = try CleanupRun(from: decoder)
        workspaces = try container.decodeIfPresent([CleanupWorkspaceReport].self, forKey: .workspaces)
        summary = try container.decodeIfPresent(CleanupSummary.self, forKey: .summary)
        applyResult = try container.decodeIfPresent(CleanupApplyResponse.self, forKey: .applyResult)
    }
}

struct CleanupRunListResponse: Codable, Sendable, Equatable {
    let ok: Bool
    let runs: [CleanupRun]
}

struct CleanupRun: Codable, Sendable, Equatable, Identifiable {
    let runID: String
    let status: CleanupRunStatus
    let phase: CleanupPhase?
    let phaseDetail: String?
    let progress: CleanupProgress?
    let phaseHistory: [CleanupPhaseHistoryEntry]
    let startedAt: String?
    let finishedAt: String?
    let session: String?
    let config: CleanupRunConfig?
    let judge: CleanupJudgeSummary?
    let error: String?

    var id: String { runID }

    enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case status, phase, phaseDetail, progress, phaseHistory, startedAt, finishedAt, session, config, judge, error
    }

    private enum WrapperCodingKeys: String, CodingKey {
        case run
    }

    init(
        runID: String,
        status: CleanupRunStatus,
        phase: CleanupPhase? = nil,
        phaseDetail: String? = nil,
        progress: CleanupProgress? = nil,
        phaseHistory: [CleanupPhaseHistoryEntry] = [],
        startedAt: String? = nil,
        finishedAt: String? = nil,
        session: String? = nil,
        config: CleanupRunConfig? = nil,
        judge: CleanupJudgeSummary? = nil,
        error: String? = nil
    ) {
        self.runID = runID
        self.status = status
        self.phase = phase
        self.phaseDetail = phaseDetail
        self.progress = progress
        self.phaseHistory = phaseHistory
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.session = session
        self.config = config
        self.judge = judge
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let topLevel = try decoder.container(keyedBy: CodingKeys.self)
        let wrapper = try decoder.container(keyedBy: WrapperCodingKeys.self)
        let nested = try wrapper.decodeIfPresent(NestedRun.self, forKey: .run)

        guard let runID = try nested?.runID ?? topLevel.decodeIfPresent(String.self, forKey: .runID) else {
            throw DecodingError.keyNotFound(
                CodingKeys.runID,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Cleanup run is missing runId")
            )
        }

        self.runID = runID
        status = try nested?.status ?? topLevel.decodeIfPresent(CleanupRunStatus.self, forKey: .status) ?? .unknown
        phase = try nested?.phase ?? topLevel.decodeIfPresent(CleanupPhase.self, forKey: .phase)
        phaseDetail = try nested?.phaseDetail ?? topLevel.decodeIfPresent(String.self, forKey: .phaseDetail)
        progress = try nested?.progress ?? topLevel.decodeIfPresent(CleanupProgress.self, forKey: .progress)
        phaseHistory = try nested?.phaseHistory ?? topLevel.decodeIfPresent([CleanupPhaseHistoryEntry].self, forKey: .phaseHistory) ?? []
        startedAt = try nested?.startedAt ?? topLevel.decodeIfPresent(String.self, forKey: .startedAt)
        finishedAt = try nested?.finishedAt ?? topLevel.decodeIfPresent(String.self, forKey: .finishedAt)
        session = try nested?.session ?? topLevel.decodeIfPresent(String.self, forKey: .session)
        config = try nested?.config ?? topLevel.decodeIfPresent(CleanupRunConfig.self, forKey: .config)
        judge = try nested?.judge ?? topLevel.decodeIfPresent(CleanupJudgeSummary.self, forKey: .judge)
        error = try nested?.error ?? topLevel.decodeIfPresent(String.self, forKey: .error)
    }

    private struct NestedRun: Decodable {
        let runID: String?
        let status: CleanupRunStatus?
        let phase: CleanupPhase?
        let phaseDetail: String?
        let progress: CleanupProgress?
        let phaseHistory: [CleanupPhaseHistoryEntry]?
        let startedAt: String?
        let finishedAt: String?
        let session: String?
        let config: CleanupRunConfig?
        let judge: CleanupJudgeSummary?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case runID = "runId"
            case status, phase, phaseDetail, progress, phaseHistory, startedAt, finishedAt, session, config, judge, error
        }
    }
}

struct CleanupProgress: Codable, Sendable, Equatable {
    let done: Int
    let total: Int

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

struct CleanupPhaseHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    let phase: CleanupPhase
    let startedAt: String?
    let finishedAt: String?
    let detail: String?

    var id: String { "\(phase.rawValue)-\(startedAt ?? "pending")" }
}

struct CleanupRunConfig: Codable, Sendable, Equatable {
    let model: String?
    let thinkingLevel: CleanupThinkingLevel
    let costThresholdUSD: Double
    let tailLines: Int?
    let minConfidence: Double?

    enum CodingKeys: String, CodingKey {
        case model, thinkingLevel, costThresholdUSD, tailLines, minConfidence
    }

    init(model: String?, thinkingLevel: CleanupThinkingLevel, costThresholdUSD: Double, tailLines: Int?, minConfidence: Double?) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.costThresholdUSD = costThresholdUSD
        self.tailLines = tailLines
        self.minConfidence = minConfidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        let rawThinkingLevel = try container.decodeIfPresent(String.self, forKey: .thinkingLevel)
        thinkingLevel = rawThinkingLevel.flatMap(CleanupThinkingLevel.init(rawValue:)) ?? .medium
        costThresholdUSD = try container.decode(Double.self, forKey: .costThresholdUSD)
        tailLines = try container.decodeIfPresent(Int.self, forKey: .tailLines)
        minConfidence = try container.decodeIfPresent(Double.self, forKey: .minConfidence)
    }
}

struct CleanupJudgeSummary: Codable, Sendable, Equatable {
    let batches: Int
    let failedBatches: Int
    let costUSD: Double
    let durationMs: Int
    let lastError: String?
}

struct CleanupWorkspaceReport: Codable, Sendable, Equatable, Identifiable {
    let workspaceID: String
    let label: String?
    let title: String?
    let workspaceReason: String?
    let summary: String?
    let workspaceCloseRecommended: Bool
    let workspaceSafeToClose: Bool
    let workspaceBlockedBy: [String]
    let git: CleanupGitStatus
    let panes: [CleanupPaneReport]

    var id: String { workspaceID }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspaceId"
        case label, title, workspaceReason, summary
        case workspaceCloseRecommended, workspaceSafeToClose, workspaceBlockedBy, git, panes
    }

    init(
        workspaceID: String,
        label: String?,
        workspaceCloseRecommended: Bool,
        workspaceSafeToClose: Bool,
        workspaceBlockedBy: [String],
        git: CleanupGitStatus,
        panes: [CleanupPaneReport],
        title: String? = nil,
        workspaceReason: String? = nil,
        summary: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.label = label
        self.title = title
        self.workspaceReason = workspaceReason
        self.summary = summary
        self.workspaceCloseRecommended = workspaceCloseRecommended
        self.workspaceSafeToClose = workspaceSafeToClose
        self.workspaceBlockedBy = workspaceBlockedBy
        self.git = git
        self.panes = panes
    }
}

struct CleanupPaneReport: Codable, Sendable, Equatable, Identifiable {
    let paneID: String
    let title: String?
    let agentKind: String?
    let agentStatus: AgentStatus
    let classification: CleanupClassification
    let confidence: Double
    let reason: String
    let closeRecommended: Bool
    let safeToClose: Bool
    let blockedBy: [String]
    let costUSD: Double?
    let costSource: String?
    let costOverThreshold: Bool
    let signals: CleanupSignals?
    let summary: String?
    let activitySummary: String?
    let usageSummary: String?
    let evidenceCited: [String]
    let piSession: CleanupPiSession?

    var id: String { paneID }

    enum CodingKeys: String, CodingKey {
        case paneID = "paneId"
        case title, agentKind, agentStatus, classification, confidence, reason, closeRecommended, safeToClose
        case blockedBy, costUSD, costSource, costOverThreshold, signals
        case summary, activitySummary, usageSummary, evidenceCited, piSession
    }

    init(
        paneID: String,
        title: String?,
        agentKind: String?,
        agentStatus: AgentStatus,
        classification: CleanupClassification,
        confidence: Double,
        reason: String,
        closeRecommended: Bool,
        safeToClose: Bool,
        blockedBy: [String],
        costUSD: Double?,
        costSource: String?,
        costOverThreshold: Bool,
        signals: CleanupSignals?,
        summary: String? = nil,
        activitySummary: String? = nil,
        usageSummary: String? = nil,
        evidenceCited: [String] = [],
        piSession: CleanupPiSession? = nil
    ) {
        self.paneID = paneID
        self.title = title
        self.agentKind = agentKind
        self.agentStatus = agentStatus
        self.classification = classification
        self.confidence = confidence
        self.reason = reason
        self.closeRecommended = closeRecommended
        self.safeToClose = safeToClose
        self.blockedBy = blockedBy
        self.costUSD = costUSD
        self.costSource = costSource
        self.costOverThreshold = costOverThreshold
        self.signals = signals
        self.summary = summary
        self.activitySummary = activitySummary
        self.usageSummary = usageSummary
        self.evidenceCited = evidenceCited
        self.piSession = piSession
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try container.decode(String.self, forKey: .paneID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        agentKind = try container.decodeIfPresent(String.self, forKey: .agentKind)
        agentStatus = try container.decodeIfPresent(AgentStatus.self, forKey: .agentStatus) ?? .unknown
        classification = try container.decode(CleanupClassification.self, forKey: .classification)
        confidence = try container.decode(Double.self, forKey: .confidence)
        reason = try container.decode(String.self, forKey: .reason)
        closeRecommended = try container.decode(Bool.self, forKey: .closeRecommended)
        safeToClose = try container.decode(Bool.self, forKey: .safeToClose)
        blockedBy = try container.decodeIfPresent([String].self, forKey: .blockedBy) ?? []
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
        costSource = try container.decodeIfPresent(String.self, forKey: .costSource)
        costOverThreshold = try container.decodeIfPresent(Bool.self, forKey: .costOverThreshold) ?? false
        signals = try container.decodeIfPresent(CleanupSignals.self, forKey: .signals)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        activitySummary = try container.decodeIfPresent(String.self, forKey: .activitySummary)
        usageSummary = try container.decodeIfPresent(String.self, forKey: .usageSummary)
        evidenceCited = try container.decodeIfPresent([String].self, forKey: .evidenceCited) ?? []
        piSession = try container.decodeIfPresent(CleanupPiSession.self, forKey: .piSession)
    }
}

struct CleanupPiSession: Codable, Sendable, Equatable {
    let detected: Bool
    let sessionID: String?
    let sessionFile: String?
    let sessionName: String?
    let cwd: String?
    let connected: Bool?
    let active: Bool
    let idle: Bool?
    let costUSD: Double?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case detected
        case sessionID = "sessionId"
        case sessionFile, sessionName, cwd, connected, active, idle, costUSD, totalTokens
    }

    init(
        detected: Bool,
        sessionID: String? = nil,
        sessionFile: String? = nil,
        sessionName: String? = nil,
        cwd: String? = nil,
        connected: Bool? = nil,
        active: Bool = false,
        idle: Bool? = nil,
        costUSD: Double? = nil,
        totalTokens: Int? = nil
    ) {
        self.detected = detected
        self.sessionID = sessionID
        self.sessionFile = sessionFile
        self.sessionName = sessionName
        self.cwd = cwd
        self.connected = connected
        self.active = active
        self.idle = idle
        self.costUSD = costUSD
        self.totalTokens = totalTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        detected = try container.decodeIfPresent(Bool.self, forKey: .detected) ?? false
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        sessionFile = try container.decodeIfPresent(String.self, forKey: .sessionFile)
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        connected = try container.decodeIfPresent(Bool.self, forKey: .connected)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
        idle = try container.decodeIfPresent(Bool.self, forKey: .idle)
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
    }
}

enum CleanupGitState: String, Codable, Sendable, Equatable {
    case clean
    case dirty
    case unpushed
    case unavailable

    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unavailable
    }
}

struct CleanupGitStatus: Codable, Sendable, Equatable {
    let state: CleanupGitState
}

enum CleanupClassification: String, Codable, Sendable, Equatable {
    case completed
    case stale
    case active
    case blocked
    case needsHuman = "needs_human"
    case unknown

    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    var label: String {
        switch self {
        case .completed: "Completed"
        case .stale: "Stale"
        case .active: "Active"
        case .blocked: "Blocked"
        case .needsHuman: "Needs you"
        case .unknown: "Unknown"
        }
    }

    var tooltip: String {
        switch self {
        case .completed: "The judge found evidence that this work is complete."
        case .stale: "The session appears inactive and no longer needs attention."
        case .active: "The session shows signs of ongoing work."
        case .blocked: "The session is blocked and needs your attention before closing."
        case .needsHuman: "The judge found work that needs a human decision."
        case .unknown: "The judge could not classify this session with confidence."
        }
    }

    var symbol: String {
        switch self {
        case .completed: "checkmark.circle.fill"
        case .stale: "clock.arrow.circlepath"
        case .active: "waveform.path.ecg"
        case .blocked: "hand.raised.fill"
        case .needsHuman: "person.crop.circle.badge.exclamationmark"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .completed: HerdrTheme.signal
        case .stale: HerdrTheme.mauve
        case .active: HerdrTheme.working
        case .blocked: HerdrTheme.alert
        case .needsHuman: HerdrTheme.alert
        case .unknown: HerdrTheme.muted
        }
    }
}

struct CleanupSignals: Codable, Sendable, Equatable {
    let doneAlertAgeSeconds: Double?
    let revisionChanged: Bool?
    let sessionFileAgeSeconds: Double?
    let starred: Bool?
    let focused: Bool?
    let unreadAlerts: Int?
    let agentStatus: AgentStatus?
    let blockedAlertAgeSeconds: Double?
    let piStateAgeSeconds: Double?
    let piConnected: Bool?
    let piActive: Bool?
    let piWorking: Bool?
    let endsAtShellPrompt: Bool?
    let hasProcessExitedMarker: Bool?
    let looksLikeIdleAgentTUI: Bool?
    let tailIsEmpty: Bool?
    let tailTruncated: Bool?

    enum CodingKeys: String, CodingKey {
        case doneAlertAgeSeconds, revisionChanged, sessionFileAgeSeconds, starred, focused, unreadAlerts
        case agentStatus, blockedAlertAgeSeconds, piStateAgeSeconds, piConnected, piActive, piWorking
        case endsAtShellPrompt, hasProcessExitedMarker
        case looksLikeIdleAgentTUI = "looksLikeIdleAgentTui"
        case tailIsEmpty, tailTruncated
    }

    init(
        doneAlertAgeSeconds: Double?,
        revisionChanged: Bool?,
        sessionFileAgeSeconds: Double?,
        starred: Bool?,
        focused: Bool?,
        unreadAlerts: Int?,
        agentStatus: AgentStatus? = nil,
        blockedAlertAgeSeconds: Double? = nil,
        piStateAgeSeconds: Double? = nil,
        piConnected: Bool? = nil,
        piActive: Bool? = nil,
        piWorking: Bool? = nil,
        endsAtShellPrompt: Bool? = nil,
        hasProcessExitedMarker: Bool? = nil,
        looksLikeIdleAgentTUI: Bool? = nil,
        tailIsEmpty: Bool? = nil,
        tailTruncated: Bool? = nil
    ) {
        self.doneAlertAgeSeconds = doneAlertAgeSeconds
        self.revisionChanged = revisionChanged
        self.sessionFileAgeSeconds = sessionFileAgeSeconds
        self.starred = starred
        self.focused = focused
        self.unreadAlerts = unreadAlerts
        self.agentStatus = agentStatus
        self.blockedAlertAgeSeconds = blockedAlertAgeSeconds
        self.piStateAgeSeconds = piStateAgeSeconds
        self.piConnected = piConnected
        self.piActive = piActive
        self.piWorking = piWorking
        self.endsAtShellPrompt = endsAtShellPrompt
        self.hasProcessExitedMarker = hasProcessExitedMarker
        self.looksLikeIdleAgentTUI = looksLikeIdleAgentTUI
        self.tailIsEmpty = tailIsEmpty
        self.tailTruncated = tailTruncated
    }
}

struct CleanupSummary: Codable, Sendable, Equatable {
    let panesScanned: Int
    let closeCandidates: Int
    let railBlocked: Int
    let costFlags: [CleanupCostFlag]
    let totalKnownCostUSD: Double
    let unknownCostPanes: Int
    let workspacesScanned: Int?
    let workspaceCloseCandidates: Int?
    let workspaceTitles: [String]?
    let workspaceSummaries: [CleanupWorkspaceSummary]?
    let classifications: [String: Int]?
    let activePanes: Int?
    let blockedPanes: Int?
    let piPanes: Int?
    let activePiSessions: Int?
    let knownCostPanes: Int?

    init(
        panesScanned: Int,
        closeCandidates: Int,
        railBlocked: Int,
        costFlags: [CleanupCostFlag],
        totalKnownCostUSD: Double,
        unknownCostPanes: Int,
        workspacesScanned: Int? = nil,
        workspaceCloseCandidates: Int? = nil,
        workspaceTitles: [String]? = nil,
        workspaceSummaries: [CleanupWorkspaceSummary]? = nil,
        classifications: [String: Int]? = nil,
        activePanes: Int? = nil,
        blockedPanes: Int? = nil,
        piPanes: Int? = nil,
        activePiSessions: Int? = nil,
        knownCostPanes: Int? = nil
    ) {
        self.panesScanned = panesScanned
        self.closeCandidates = closeCandidates
        self.railBlocked = railBlocked
        self.costFlags = costFlags
        self.totalKnownCostUSD = totalKnownCostUSD
        self.unknownCostPanes = unknownCostPanes
        self.workspacesScanned = workspacesScanned
        self.workspaceCloseCandidates = workspaceCloseCandidates
        self.workspaceTitles = workspaceTitles
        self.workspaceSummaries = workspaceSummaries
        self.classifications = classifications
        self.activePanes = activePanes
        self.blockedPanes = blockedPanes
        self.piPanes = piPanes
        self.activePiSessions = activePiSessions
        self.knownCostPanes = knownCostPanes
    }
}

struct CleanupWorkspaceSummary: Codable, Sendable, Equatable, Identifiable {
    let workspaceID: String
    let title: String
    let summary: String
    let workspaceReason: String
    let paneCount: Int
    let closeCandidates: Int
    let railBlocked: Int
    let activePanes: Int
    let piPanes: Int
    let activePiSessions: Int

    var id: String { workspaceID }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspaceId"
        case title, summary, workspaceReason, paneCount, closeCandidates, railBlocked
        case activePanes, piPanes, activePiSessions
    }
}

struct CleanupCostFlag: Codable, Sendable, Equatable, Identifiable {
    let paneID: String
    let costUSD: Double

    var id: String { paneID }

    enum CodingKeys: String, CodingKey {
        case paneID = "paneId"
        case costUSD
    }
}

enum CleanupRail {
    private static let labels = [
        "R1:working": "agent is still working",
        "R1:blocked": "agent is blocked and needs you",
        "R2:focused": "currently focused pane",
        "R2:focused_workspace": "in the focused workspace",
        "R3:starred": "starred",
        "R4:active_output": "produced output during the check",
        "R5:unread_alerts": "has unread alerts",
        "R6:git_dirty": "uncommitted changes",
        "R6:git_unpushed": "unpushed commits",
        "R6:git_unknown": "git state unknown",
        "R6:pane_blocked": "a pane inside is not closable",
        "R7:low_confidence": "judge confidence too low",
        "R8:state_changed": "state changed since the report",
        "not_safe_to_close": "not approved as safe to close",
        "pi_quit_failed": "Pi session could not end cleanly",
        "workspace_pi_quit_aborted": "not attempted after another Pi session failed",
        "pi_still_active": "Pi session stayed active after quit",
    ]

    static func label(for code: String) -> String { labels[code] ?? code }
}

struct CleanupStartRunRequest: Codable, Sendable, Equatable {
    let model: String?
    let thinkingLevel: CleanupThinkingLevel?
    let costThresholdUSD: Double?
    let tailLines: Int?
    let keepEvidence: Bool?
    let workspaceIDs: [String]?
    let judgeCharter: String?

    enum CodingKeys: String, CodingKey {
        case model, thinkingLevel, costThresholdUSD, tailLines, keepEvidence
        case workspaceIDs = "workspaceIds"
        case judgeCharter
    }

    init(
        model: String?,
        thinkingLevel: CleanupThinkingLevel?,
        costThresholdUSD: Double?,
        tailLines: Int?,
        keepEvidence: Bool?,
        workspaceIDs: [String]?,
        judgeCharter: String? = nil
    ) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.costThresholdUSD = costThresholdUSD
        self.tailLines = tailLines
        self.keepEvidence = keepEvidence
        self.workspaceIDs = workspaceIDs
        self.judgeCharter = judgeCharter
    }
}

struct CleanupStartRunResponse: Codable, Sendable, Equatable {
    let ok: Bool
    let runID: String
    let status: CleanupRunStatus

    enum CodingKeys: String, CodingKey {
        case ok
        case runID = "runId"
        case status
    }
}

struct CleanupApplyRequest: Codable, Sendable, Equatable {
    let paneIDs: [String]
    let workspaceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case paneIDs = "paneIds"
        case workspaceIDs = "workspaceIds"
    }
}

struct CleanupApplyResponse: Codable, Sendable, Equatable {
    let applied: CleanupAppliedItems
    let skipped: [CleanupSkippedItem]
    let piSessions: CleanupPiSessionApplySummary?
    let ledger: CleanupLedgerSummary?
    let deduplicatedPaneIDs: [String]?
    let complete: Bool?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case applied, skipped, piSessions, ledger, complete, error
        case deduplicatedPaneIDs = "deduplicatedPaneIds"
    }

    init(
        applied: CleanupAppliedItems,
        skipped: [CleanupSkippedItem],
        piSessions: CleanupPiSessionApplySummary? = nil,
        ledger: CleanupLedgerSummary? = nil,
        deduplicatedPaneIDs: [String]? = nil,
        complete: Bool? = nil,
        error: String? = nil
    ) {
        self.applied = applied
        self.skipped = skipped
        self.piSessions = piSessions
        self.ledger = ledger
        self.deduplicatedPaneIDs = deduplicatedPaneIDs
        self.complete = complete
        self.error = error
    }
}

struct CleanupPiSessionApplySummary: Codable, Sendable, Equatable {
    let ended: Int
    let failed: Int
    let results: [CleanupPiSessionApplyResult]
}

struct CleanupPiSessionApplyResult: Codable, Sendable, Equatable, Identifiable {
    let paneID: String
    let sessionID: String?
    let wasActive: Bool
    let quitAttempted: Bool
    let quitSucceeded: Bool
    let closeOutcome: String
    let reason: String?

    var id: String { paneID }

    enum CodingKeys: String, CodingKey {
        case paneID = "paneId"
        case sessionID = "sessionId"
        case wasActive, quitAttempted, quitSucceeded, closeOutcome, reason
    }
}

struct CleanupLedgerSummary: Codable, Sendable, Equatable {
    let path: String
    let recordsAppended: Int
    let records: [CleanupLedgerRecord]
}

struct CleanupLedgerRecord: Codable, Sendable, Equatable, Identifiable {
    struct Quit: Codable, Sendable, Equatable {
        let attempted: Bool
        let succeeded: Bool
        let outcome: String
        let error: String?
    }

    struct Close: Codable, Sendable, Equatable {
        let scope: String
        let outcome: String
        let error: String?
    }

    let cleanupRunID: String
    let timestamp: String
    let workspace: CleanupLedgerWorkspace
    let pane: CleanupLedgerPane
    let piSession: CleanupPiSession
    let quit: Quit
    let close: Close

    var id: String { "\(cleanupRunID):\(pane.id):\(timestamp)" }

    enum CodingKeys: String, CodingKey {
        case cleanupRunID = "cleanupRunId"
        case timestamp, workspace, pane, piSession, quit, close
    }
}

struct CleanupLedgerWorkspace: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
}

struct CleanupLedgerPane: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let tabID: String?
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case tabID = "tabId"
        case cwd
    }
}

struct CleanupAppliedItems: Codable, Sendable, Equatable {
    let panes: [String]
    let workspaces: [String]
}

struct CleanupSkippedItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let reason: String

    var reasonLabel: String { CleanupRail.label(for: reason) }
}

struct CleanupModelCatalog: Codable, Sendable, Equatable {
    let ok: Bool
    let models: [CleanupAvailableModel]
    let defaultModel: CleanupModelDefault?

    enum CodingKeys: String, CodingKey {
        case ok, models
        case defaultModel = "default"
    }
}

struct CleanupAvailableModel: Codable, Sendable, Equatable, Identifiable {
    let provider: String
    let modelID: String
    let name: String?
    let contextWindow: Int?

    var id: String { "\(provider)/\(modelID)" }
    var displayName: String {
        guard let name, !name.isEmpty else { return modelID }
        return name
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case modelID = "id"
        case name
        case contextWindow
    }
}

struct CleanupModelDefault: Codable, Sendable, Equatable {
    let provider: String?
    let modelID: String?
    let thinkingLevel: CleanupThinkingLevel

    var fullID: String? {
        guard let modelID else { return nil }
        guard let provider else { return modelID }
        return "\(provider)/\(modelID)"
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case modelID = "id"
        case thinkingLevel
    }

    init(provider: String?, modelID: String?, thinkingLevel: CleanupThinkingLevel) {
        self.provider = provider
        self.modelID = modelID
        self.thinkingLevel = thinkingLevel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        let rawThinkingLevel = try container.decodeIfPresent(String.self, forKey: .thinkingLevel)
        thinkingLevel = rawThinkingLevel.flatMap(CleanupThinkingLevel.init(rawValue:)) ?? .medium
    }
}
