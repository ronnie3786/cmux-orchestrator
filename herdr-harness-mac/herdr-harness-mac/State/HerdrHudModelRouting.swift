enum HerdrHudModelRouting {
    static let visionModel = "openai-codex/gpt-5.6-luna"
    static let thinkingLevel = "max"

    static func model(hasAttachments: Bool) -> String? {
        hasAttachments ? visionModel : nil
    }
}
