import Foundation

enum PiConversationTimestamp {
    // ISO8601DateFormatter is documented as thread-safe. These immutable
    // formatters avoid allocating one for every streamed or snapshot entry.
    // TODO: Revisit if Foundation changes that thread-safety guarantee.
    nonisolated(unsafe) private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let withoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from value: PiJSONValue?) -> Date? {
        guard let value else { return nil }
        switch value {
        case let .number(number):
            // Pi message timestamps are milliseconds, while extension metadata
            // occasionally uses seconds.
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number)
        case let .string(string):
            if let number = Double(string) {
                return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number)
            }
            if let date = withFractional.date(from: string) { return date }
            return withoutFractional.date(from: string)
        case .bool, .object, .array, .null:
            return nil
        }
    }
}
