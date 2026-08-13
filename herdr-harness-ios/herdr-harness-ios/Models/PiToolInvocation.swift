import Foundation

struct PiToolInvocation: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case waiting
        case running
        case succeeded
        case failed
    }

    let id: String
    let callID: String
    var name: String
    var arguments: PiJSONValue?
    var result: PiJSONValue?
    var status: Status
    var startedAt: Date?
    var finishedAt: Date?
}
