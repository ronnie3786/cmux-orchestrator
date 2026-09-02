import Testing
@testable import herdr_harness_ios

@Suite("Agent model resolution")
struct AgentModelResolutionTests {
    @Test("Empty preferences omit the model")
    func emptyPreferencesOmitTheModel() {
        for preference: String? in [nil, "", " \n\t "] {
            let resolution = AgentModelResolver.resolve(
                preference: preference,
                catalog: [],
                isCatalogAuthoritative: true
            )
            #expect(resolution.modelID == nil)
            #expect(!resolution.preferenceIsUnavailable)
        }
    }

    @Test("An authoritative catalog accepts its stored preference")
    func authoritativeCatalogAcceptsItsStoredPreference() {
        let candidate = model(provider: "provider", id: "model")
        let resolution = AgentModelResolver.resolve(
            preference: candidate.id,
            catalog: [candidate],
            isCatalogAuthoritative: true
        )
        #expect(resolution.modelID == candidate.id)
        #expect(!resolution.preferenceIsUnavailable)
    }

    @Test("An authoritative catalog rejects an unavailable preference")
    func authoritativeCatalogRejectsAnUnavailablePreference() {
        let resolution = AgentModelResolver.resolve(
            preference: "provider/missing",
            catalog: [],
            isCatalogAuthoritative: true
        )
        #expect(resolution.modelID == nil)
        #expect(resolution.preferenceIsUnavailable)
    }

    @Test("An unavailable catalog preserves the stored preference")
    func unavailableCatalogPreservesTheStoredPreference() {
        let resolution = AgentModelResolver.resolve(
            preference: "provider/model",
            catalog: [],
            isCatalogAuthoritative: false
        )
        #expect(resolution.modelID == "provider/model")
        #expect(!resolution.preferenceIsUnavailable)
    }

    @Test("Resolution matches the catalog's composed provider and model ID")
    func resolutionMatchesComposedCatalogID() {
        let candidate = PiAvailableModel(
            provider: "anthropic",
            modelID: "claude-sonnet-4-5",
            name: nil,
            reasoning: nil,
            contextWindow: nil
        )
        let resolution = AgentModelResolver.resolve(
            preference: "anthropic/claude-sonnet-4-5",
            catalog: [candidate],
            isCatalogAuthoritative: true
        )
        #expect(resolution.modelID == candidate.id)
        #expect(!resolution.preferenceIsUnavailable)
    }

    private func model(provider: String, id: String) -> PiAvailableModel {
        PiAvailableModel(
            provider: provider,
            modelID: id,
            name: nil,
            reasoning: nil,
            contextWindow: nil
        )
    }
}
