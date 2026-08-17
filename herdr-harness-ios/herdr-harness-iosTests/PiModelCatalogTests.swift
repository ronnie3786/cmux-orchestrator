import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Pi model catalog")
struct PiModelCatalogTests {
    @Test("Thinking level raw values match Pi's canonical order")
    func thinkingLevelRawValuesArePinned() {
        #expect(PiThinkingLevel.allCases.map(\.rawValue) == [
            "off", "minimal", "low", "medium", "high", "xhigh", "max"
        ])
    }

    @Test("Model identity accepts canonical and fallback identifiers")
    func decodesModelIdentity() throws {
        let named = try JSONDecoder().decode(
            PiJSONValue.self,
            from: Data("{\"provider\":\"anthropic\",\"id\":\"claude-3\",\"name\":\"Claude 3\"}".utf8)
        )
        let fallback = try JSONDecoder().decode(
            PiJSONValue.self,
            from: Data("{\"provider\":\"openai\",\"modelId\":\"gpt-5\",\"name\":\"\"}".utf8)
        )

        let identity = PiModelIdentity(json: named)
        let fallbackIdentity = PiModelIdentity(json: fallback)

        #expect(identity?.provider == "anthropic")
        #expect(identity?.id == "claude-3")
        #expect(identity?.name == "Claude 3")
        #expect(identity?.displayName == "Claude 3")
        #expect(fallbackIdentity?.id == "gpt-5")
        #expect(fallbackIdentity?.displayName == "gpt-5")
        #expect(PiModelIdentity(json: nil) == nil)
        #expect(PiModelIdentity(json: .null) == nil)
    }

    @Test("Available models decode wire identifiers and context aliases")
    func decodesAvailableModels() throws {
        let snakeCase = try JSONDecoder().decode(
            PiAvailableModel.self,
            from: Data("{\"provider\":\"anthropic\",\"id\":\"claude-3\",\"context_window\":200000}".utf8)
        )
        let camelCase = try JSONDecoder().decode(
            PiAvailableModel.self,
            from: Data("{\"provider\":\"openai\",\"id\":\"gpt-5\",\"contextWindow\":128000}".utf8)
        )

        #expect(snakeCase.modelID == "claude-3")
        #expect(snakeCase.contextWindow == 200000)
        #expect(snakeCase.id == "anthropic/claude-3")
        #expect(camelCase.contextWindow == 128000)
    }

    @Test("Catalog response decodes the bridge success envelope")
    func decodesCatalogSuccessResponse() throws {
        let success = try JSONDecoder().decode(
            PiModelCatalogResponse.self,
            from: Data("""
            {"success":true,"result":{"models":[{"provider":"anthropic","id":"claude-3","name":"Claude 3","reasoning":true,"context_window":200000}],"current":{"provider":"anthropic","id":"claude-3"}}}
            """.utf8)
        )

        #expect(success.accepted)
        #expect(success.models.count == 1)
        #expect(success.models[0].reasoning == true)
        #expect(success.models[0].contextWindow == 200000)
        #expect(success.current?.id == "claude-3")
    }

    @Test("Catalog response also tolerates a legacy ok key")
    func decodesLegacyCatalogSuccessResponse() throws {
        let success = try JSONDecoder().decode(
            PiModelCatalogResponse.self,
            from: Data("{\"ok\":true,\"result\":{\"models\":[],\"current\":null}}".utf8)
        )

        #expect(success.accepted)
        #expect(success.models.isEmpty)
        #expect(success.current == nil)
    }
}
