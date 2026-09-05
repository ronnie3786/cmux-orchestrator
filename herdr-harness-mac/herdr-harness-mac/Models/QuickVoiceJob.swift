import Foundation

struct QuickVoiceJob: Decodable, Identifiable, Equatable, Sendable {
    struct Quest: Decodable, Identifiable, Equatable, Sendable {
        let title: String
        let status: String
        let paneID: String?
        let result: String?
        var id: String { paneID ?? title }
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
    var statusLabel: String {
        switch status {
        case "planning": "Planning side quests"
        case "starting": "Starting chats"
        case "running": "\(tasks.filter { $0.status == "done" }.count)/\(tasks.count) finished"
        case "done": "Finished"
        case "needs_attention": "Needs your attention"
        case "failed": "Couldn’t complete request"
        default: "Working"
        }
    }
}
