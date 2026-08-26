import Foundation

struct WorkInboxProviderSection<Item: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var ok: Bool
    var items: [Item]
    var error: String?

    static var empty: Self {
        Self(ok: true, items: [], error: nil)
    }
}
