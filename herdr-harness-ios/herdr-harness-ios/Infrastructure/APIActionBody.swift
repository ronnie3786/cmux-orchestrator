import Foundation

struct APIActionBody: Encodable, Sendable {
    var text: String?
    var label: String?
    var cwd: String?
    var direction: String?
    var ratio: Double?
    var keys: [String]?
    var submit: Bool?
    var kind: String?
    var name: String?
    var command: String?

    init(
        text: String? = nil,
        label: String? = nil,
        cwd: String? = nil,
        direction: String? = nil,
        ratio: Double? = nil,
        keys: [String]? = nil,
        submit: Bool? = nil,
        kind: String? = nil,
        name: String? = nil,
        command: String? = nil
    ) {
        self.text = text
        self.label = label
        self.cwd = cwd
        self.direction = direction
        self.ratio = ratio
        self.keys = keys
        self.submit = submit
        self.kind = kind
        self.name = name
        self.command = command
    }
}
