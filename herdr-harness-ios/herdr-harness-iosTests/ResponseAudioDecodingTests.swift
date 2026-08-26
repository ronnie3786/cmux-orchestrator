import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Response audio API")
struct ResponseAudioDecodingTests {
    @Test("Capabilities expose only available actions")
    func capabilitiesDecode() throws {
        let capabilities = try JSONDecoder().decode(
            ResponseAudioCapabilities.self,
            from: Data("{\"ok\":true,\"available\":true,\"listen\":true,\"tldr\":false}".utf8)
        )

        #expect(capabilities.supports(.listen))
        #expect(!capabilities.supports(.tldr))
    }

    @Test("Prepared speech preserves ordered chunks")
    func preparedChunksDecode() throws {
        let response = try JSONDecoder().decode(
            ResponseAudioPrepareResponse.self,
            from: Data("{\"ok\":true,\"action\":\"tldr\",\"chunks\":[\"First\",\"Second\"]}".utf8)
        )

        #expect(response.action == .tldr)
        #expect(response.chunks == ["First", "Second"])
    }

    @Test("Playback phase reports its active action")
    func playbackPhaseAction() {
        #expect(ResponseAudioPlaybackPhase.idle.activeAction == nil)
        #expect(ResponseAudioPlaybackPhase.playing(.listen).activeAction == .listen)
        #expect(ResponseAudioPlaybackPhase.paused(.tldr).activeAction == .tldr)
    }
}
