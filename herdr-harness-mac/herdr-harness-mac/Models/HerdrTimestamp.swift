import Foundation

enum HerdrTimestamp {
    // ISO8601DateFormatter is documented as thread-safe. Reusing these
    // immutable instances avoids rebuilding formatters for every snapshot.
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

    static func date(from value: String) -> Date? {
        withFractional.date(from: value) ?? withoutFractional.date(from: value)
    }

    static func string(from date: Date) -> String {
        withoutFractional.string(from: date)
    }

    static func compactAge(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    static func spokenAge(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return agePhrase(minutes, unit: "minute") }
        let hours = minutes / 60
        if hours < 24 { return agePhrase(hours, unit: "hour") }
        return agePhrase(hours / 24, unit: "day")
    }

    private static func agePhrase(_ value: Int, unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s") ago"
    }
}
