import Foundation

/// Context usage for the active model, as reported by the Pi semantic bridge.
/// `tokens` and `percent` are legitimately null right after compaction (before
/// the next LLM response), so consumers must tolerate unknown values.
struct PiContextUsage: Equatable, Sendable {
    let tokens: Int?
    let contextWindow: Int?
    let percent: Double?

    init?(from value: PiJSONValue?) {
        guard let value else { return nil }
        let tokens = value.number(for: "tokens").map(Int.init)
        let contextWindow = value.number(for: "contextWindow", "context_window").map(Int.init)
        let percent = value.number(for: "percent")
        guard tokens != nil || contextWindow != nil || percent != nil else { return nil }
        self.tokens = tokens
        self.contextWindow = contextWindow
        self.percent = percent
    }

    /// Usage as a 0...1 fraction of the context window.
    var fraction: Double? {
        if let tokens, let contextWindow, contextWindow > 0 {
            return min(1, Double(tokens) / Double(contextWindow))
        }
        if let percent {
            return min(1, max(0, percent / 100))
        }
        return nil
    }

    /// A short display form such as "12.3k / 192k".
    var summary: String? {
        if let tokens, let contextWindow, contextWindow > 0 {
            return "\(Self.compact(tokens)) / \(Self.compact(contextWindow))"
        }
        if let tokens {
            return Self.compact(tokens)
        }
        return nil
    }

    var percentText: String? {
        fraction.map { "\(Int(($0 * 100).rounded()))%" }
    }

    private static func compact(_ value: Int) -> String {
        if value >= 1_000_000 {
            let millions = Double(value) / 1_000_000
            return String(format: millions >= 10 ? "%.0fM" : "%.1fM", millions)
        }
        if value >= 100_000 {
            return "\(Int((Double(value) / 1_000).rounded()))k"
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
