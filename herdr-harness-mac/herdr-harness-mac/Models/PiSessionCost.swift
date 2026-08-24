import Foundation

/// Cumulative cost of the current Pi session, as reported by the semantic
/// bridge. `totalUSD` is null when the bridge predates cost reporting or the
/// session has no billed usage yet, so consumers must tolerate unknown values.
struct PiSessionCost: Equatable, Sendable {
    let totalUSD: Double?
    let totalTokens: Int?

    init?(from value: PiJSONValue?) {
        guard let value else { return nil }
        let totalUSD = value.number(for: "totalUSD", "total_usd")
        let totalTokens = value.number(for: "totalTokens", "total_tokens").map(Int.init)
        guard totalUSD != nil || totalTokens != nil else { return nil }
        self.totalUSD = totalUSD
        self.totalTokens = totalTokens
    }

    /// A short display form such as "$1.87". "<$0.01" floor for tiny non-zero
    /// costs; cents dropped at $100+.
    var summary: String? {
        guard let totalUSD else { return nil }
        if totalUSD > 0 && totalUSD < 0.01 { return "<$0.01" }
        return String(format: totalUSD >= 100 ? "$%.0f" : "$%.2f", totalUSD)
    }
}
