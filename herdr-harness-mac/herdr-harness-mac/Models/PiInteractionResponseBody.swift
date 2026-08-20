import Foundation

struct PiInteractionResponseBody: Encodable, Equatable, Sendable {
    var value: PiJSONValue?
    var confirmed: Bool?
    var cancelled: Bool?

    static func selection(_ value: String) -> PiInteractionResponseBody {
        PiInteractionResponseBody(value: .string(value))
    }

    static func text(_ value: String) -> PiInteractionResponseBody {
        PiInteractionResponseBody(value: .string(value))
    }

    static func confirmation(_ value: Bool) -> PiInteractionResponseBody {
        PiInteractionResponseBody(confirmed: value)
    }

    static let cancelled = PiInteractionResponseBody(cancelled: true)
}
