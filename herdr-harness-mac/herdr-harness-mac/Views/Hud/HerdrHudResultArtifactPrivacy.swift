import Foundation

/// Centralizes the shoulder-surfing boundary for result copy. Native open and
/// file-system errors can contain a filename or cache path, so hiding session
/// titles must hide those diagnostics as well as the primary result label.
enum HerdrHudResultArtifactPrivacy {
    static func visibleFailureDetail(
        _ message: String,
        revealsSensitiveDetails: Bool
    ) -> String? {
        guard revealsSensitiveDetails else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
