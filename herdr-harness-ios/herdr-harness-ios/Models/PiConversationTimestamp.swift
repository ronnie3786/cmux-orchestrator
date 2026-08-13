import Foundation

enum PiConversationTimestamp {
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
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        case .bool, .object, .array, .null:
            return nil
        }
    }
}
