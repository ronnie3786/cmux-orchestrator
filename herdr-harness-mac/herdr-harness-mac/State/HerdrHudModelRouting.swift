enum HerdrHudModelRouting {
    static let visionModel = "openai-codex/gpt-5.6-luna"
    static let thinkingLevel = "max"

    static func model(
        selection: String?,
        selectionSupportsImages: Bool,
        hasAttachments: Bool
    ) -> String? {
        if let selection {
            if !hasAttachments { return selection }
            return selectionSupportsImages ? selection : visionModel
        }
        return hasAttachments ? visionModel : nil
    }
}
