import Testing
@testable import herdr_harness_mac

@Suite("Pi model display names")
struct PiModelDisplayNameTests {
    @Test("Ground truth names")
    func groundTruth() {
        let cases: [(String, String, String?, String)] = [
            ("custom-lux-dflash2", "qwen3.8-27b-nvfp4-dflash2", nil, "Qwen3.8 27B"),
            ("custom-lux-dspark", "qwen3.8-27b-nvfp4-dspark", nil, "Qwen3.8 27B"),
            ("custom-lux-uncensored", "qwen3.8-27b-aeon-uncensored-nvfp4-mtp", nil, "Qwen3.8 27B Aeon Uncensored"),
            ("openai-codex", "gpt-5.3-codex-spark", nil, "GPT-5.3 Codex Spark"),
            ("openai-codex", "gpt-5.4", nil, "GPT-5.4"),
            ("openai-codex", "gpt-5.4-mini", nil, "GPT-5.4 Mini"),
            ("openai-codex", "gpt-5.5", nil, "GPT-5.5"),
            ("openai-codex", "gpt-5.6-luna", nil, "GPT-5.6 Luna"),
            ("openai-codex", "gpt-5.6-sol", nil, "GPT-5.6 Sol"),
            ("openai-codex", "gpt-5.6-terra", nil, "GPT-5.6 Terra"),
            ("ollama-cloud", "glm-5.3", nil, "GLM-5.3"),
            ("anthropic", "claude-sonnet-4-5-20250929", nil, "Claude Sonnet 4.5"),
            ("fireworks", "deepseek-v4-flash-0731", nil, "DeepSeek V4 Flash")
        ]

        for (provider, modelID, name, expected) in cases {
            #expect(PiModelDisplayName.short(provider: provider, modelID: modelID, name: name) == expected)
        }
    }

    @Test("Provider marketing labels and namespace prefixes use the same short name")
    func canonicalLabels() {
        #expect(PiModelDisplayName.short(provider: "anthropic", modelID: "claude-sonnet-4-5-20250929", name: "Claude Sonnet 4.5 (latest, thinking)") == "Claude Sonnet 4.5")
        #expect(PiModelDisplayName.short(provider: "openrouter", modelID: "anthropic/claude-sonnet-4-5", name: "Anthropic: Claude Sonnet 4.5") == "Claude Sonnet 4.5")
        #expect(PiModelDisplayName.short(provider: "openai", modelID: "gpt-5.4-2026-03-05", name: nil) == "GPT-5.4")
        #expect(PiModelDisplayName.short(fullID: "openai-codex/gpt-5.6-sol") == "GPT-5.6 Sol")
    }

    @Test("Handles edge cases")
    func edgeCases() {
        #expect(PiModelDisplayName.short(provider: "anthropic", modelID: "20250929", name: nil) == "20250929")
        #expect(PiModelDisplayName.short(provider: "openai-codex", modelID: "gpt-5", name: "") == "GPT-5")
        #expect(PiModelDisplayName.short(provider: "openai-codex", modelID: "gpt-5", name: "   ") == "GPT-5")
        #expect(PiModelDisplayName.short(provider: "acme", modelID: "mystery-model-x9", name: nil) == "Mystery Model X9")
    }

    @Test("Normalized names are idempotent for safe cases")
    func idempotency() {
        for (provider, modelID) in [("openai-codex", "gpt-5.6-luna"), ("fireworks", "deepseek-v4-flash-0731")] {
            let normalized = PiModelDisplayName.short(provider: provider, modelID: modelID, name: nil)
            #expect(PiModelDisplayName.short(provider: provider, modelID: modelID, name: normalized) == normalized)
        }
    }
}
