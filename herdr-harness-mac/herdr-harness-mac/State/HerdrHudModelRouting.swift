/// Routes HUD submissions. Only image attachments require a vision-capable model,
/// and `hasImageAttachments` means at least one attachment is an image.
enum HerdrHudModelRouting {
    /// Retained as the built-in fallback. Settings can now override it via
    /// `AgentModelSettings.visionModel`; this value is what ships in the app.
    static let visionModel = AgentModelSettings.builtInVisionModel
    static let thinkingLevel = AgentModelSettings.builtInThinkingLevel.rawValue

    static func model(
        selection: String?,
        selectionSupportsImages: Bool,
        hasImageAttachments: Bool,
        visionModel: String = Self.visionModel
    ) -> String? {
        if let selection {
            if !hasImageAttachments { return selection }
            return selectionSupportsImages ? selection : visionModel
        }
        return hasImageAttachments ? visionModel : nil
    }
}
