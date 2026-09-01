import Foundation

/// Turns whatever the user pasted into a pane id `HerdrAppModel` can route to.
///
/// Pane references travel by copy-paste — out of a URL bar, a chat message, a
/// log line — so by the time one reaches this field it may be percent-encoded,
/// wrapped in the punctuation of whatever quoted it, or a whole deep link
/// rather than a bare id. Normalizing here rather than at the call site keeps
/// every accepted spelling in one testable place.
enum PaneReference {
    private static let wrappingPunctuation = CharacterSet(charactersIn: "`'\"<>")

    /// Returns a routable pane id, or `nil` when there is nothing usable.
    ///
    /// Accepted spellings, in the order they are tried:
    /// - a full deep link (`herdr://pane?pane_id=…`, `herdr://pane/…`, or the
    ///   universal-link `https://…/open/pane/…` form), delegated to
    ///   `HerdrAppModel.paneID(from:)` so the URL grammar lives in one place
    /// - a machine-scoped id, `machine|w1:p2`, passed through untouched
    /// - a bare id, `w1:p2`
    /// - any of the above percent-encoded, e.g. `w1%3Ap2`
    static func normalize(_ raw: String) -> String? {
        var reference = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        reference = reference.trimmingCharacters(in: wrappingPunctuation)

        if reference.contains("%"),
           let decoded = reference.removingPercentEncoding,
           decoded != reference,
           !decoded.isEmpty {
            reference = decoded
        }

        reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        reference = reference.trimmingCharacters(in: wrappingPunctuation)

        if let url = URL(string: reference),
           let scheme = url.scheme?.lowercased(),
           ["herdr", "http", "https"].contains(scheme) {
            return HerdrAppModel.paneID(from: url)
        }

        guard !reference.isEmpty,
              !reference.contains(where: \.isWhitespace),
              !reference.contains("://") else { return nil }
        return reference
    }
}
