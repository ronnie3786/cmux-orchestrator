import Foundation

struct QuickVoiceJob: Decodable, Identifiable, Equatable, Sendable {
    struct Quest: Decodable, Identifiable, Equatable, Sendable {
        let title: String
        let status: String
        let paneID: String?
        let result: String?
        var id: String { paneID ?? title }

        var statusLabel: String {
            switch status {
            case "pending", "starting": "Starting"
            case "sending": "Sending request"
            case "running": "Running"
            case "done": "Finished"
            case "needs_attention": "Needs your attention"
            case "failed": "Couldn't finish"
            default: "Checking status"
            }
        }

        var statusSymbol: String {
            switch status {
            case "done": "checkmark.circle.fill"
            case "needs_attention", "failed": "exclamationmark.circle.fill"
            case "running": "bolt.circle.fill"
            default: "clock"
            }
        }

        var hudStatus: AgentStatus {
            switch status {
            case "done": .done
            case "needs_attention", "failed": .blocked
            default: .working
            }
        }
    }

    struct Message: Decodable, Identifiable, Equatable, Sendable {
        let id: String
        let text: String
        let audioStatus: String
    }

    let id: String
    let text: String
    let cwd: String?
    let title: String
    let status: String
    let createdAt: TimeInterval
    let tasks: [Quest]
    let messages: [Message]
    let error: String?

    var isFinished: Bool { ["done", "failed", "needs_attention"].contains(status) }
    var needsAttention: Bool {
        status == "needs_attention" || status == "failed" || tasks.contains { $0.hudStatus == .blocked }
    }
    var statusSymbol: String {
        if needsAttention { return "exclamationmark.circle.fill" }
        if status == "done" { return "checkmark.circle" }
        return tasks.isEmpty ? "sparkles" : "person.2.fill"
    }
    var statusLabel: String {
        switch status {
        case "planning": "Organizing your agents…"
        case "starting": "Starting \(tasks.count) agent\(tasks.count == 1 ? "" : "s")…"
        case "running": progressLabel
        case "done": "Finished"
        case "needs_attention": "Needs your attention"
        case "failed": "Couldn’t complete request"
        default: "Working"
        }
    }

    private var progressLabel: String {
        let done = tasks.count { $0.status == "done" }
        let blocked = tasks.count { $0.hudStatus == .blocked }
        let running = tasks.count { $0.status == "running" }
        if blocked > 0 { return "\(blocked) agent\(blocked == 1 ? " needs" : "s need") attention" }
        if done == tasks.count, !tasks.isEmpty { return "Agents finished. Preparing your report…" }
        if done > 0 { return "\(done) of \(tasks.count) agents finished" }
        return "\(running) agent\(running == 1 ? "" : "s") running"
    }
}
