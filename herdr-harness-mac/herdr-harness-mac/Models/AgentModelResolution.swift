import Foundation

struct AgentModelResolution: Equatable, Sendable {
    /// nil means "omit `model` from the request" — the harness's pi default wins.
    let modelID: String?
    /// True when a stored preference existed but the catalog we hold does not
    /// offer it. The UI shows a warning; the request still falls back cleanly.
    let preferenceIsUnavailable: Bool
}

enum AgentModelResolver {
    static func resolve(
        preference: String?,
        catalog: [PiAvailableModel],
        isCatalogAuthoritative: Bool
    ) -> AgentModelResolution {
        let trimmed = preference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return .init(modelID: nil, preferenceIsUnavailable: false) }
        guard isCatalogAuthoritative else { return .init(modelID: trimmed, preferenceIsUnavailable: false) }
        guard catalog.contains(where: { $0.id == trimmed }) else {
            return .init(modelID: nil, preferenceIsUnavailable: true)
        }
        return .init(modelID: trimmed, preferenceIsUnavailable: false)
    }
}
