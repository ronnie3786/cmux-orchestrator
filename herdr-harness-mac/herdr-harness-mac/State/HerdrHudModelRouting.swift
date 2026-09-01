enum HerdrHudModelRouting {
    /// Retained as the built-in fallback. Settings can now override it via
    /// `AgentModelSettings.visionModel`; this value is what ships in the app.
    static let visionModel = AgentModelSettings.builtInVisionModel
    static let thinkingLevel = AgentModelSettings.builtInThinkingLevel.rawValue

    static func model(
        selection: String?,
        selectionSupportsImages: Bool,
        hasAttachments: Bool,
        visionModel: String = Self.visionModel
    ) -> String? {
        if let selection {
            if !hasAttachments { return selection }
            return selectionSupportsImages ? selection : visionModel
        }
        return hasAttachments ? visionModel : nil
    }
}
