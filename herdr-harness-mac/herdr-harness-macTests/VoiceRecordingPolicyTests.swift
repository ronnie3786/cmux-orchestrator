import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Voice recording policy")
struct VoiceRecordingPolicyTests {
    @Test("Enforces the 20 MB recording ceiling before reading data")
    func enforcesByteLimit() throws {
        try VoiceRecordingPolicy.validateByteCount(VoiceRecordingPolicy.maximumBytes)
        #expect(throws: VoiceTranscriptionError.recordingTooLarge) {
            try VoiceRecordingPolicy.validateByteCount(VoiceRecordingPolicy.maximumBytes + 1)
        }
        #expect(throws: VoiceTranscriptionError.invalidRecording) {
            try VoiceRecordingPolicy.validateByteCount(0)
        }
    }

    @Test("Accepts bounded WAV audio and rejects disguised files")
    func validatesWAVHeader() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "herdr-voice-policy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let validURL = directory.appending(path: "voice.wav")
        var valid = Data("RIFF".utf8)
        valid.append(contentsOf: [38, 0, 0, 0])
        valid.append(Data("WAVEfmt ".utf8))
        valid.append(contentsOf: [16, 0, 0, 0])
        valid.append(contentsOf: [1, 0, 1, 0])
        valid.append(contentsOf: [0x80, 0x3E, 0, 0])
        valid.append(contentsOf: [0, 0x7D, 0, 0])
        valid.append(contentsOf: [2, 0, 16, 0])
        valid.append(Data("data".utf8))
        valid.append(contentsOf: [2, 0, 0, 0, 0, 0])
        try valid.write(to: validURL)

        #expect(try VoiceRecordingPolicy.validatedData(at: validURL) == valid)

        let disguisedURL = directory.appending(path: "disguised.wav")
        try Data("not audio".utf8).write(to: disguisedURL)
        #expect(throws: VoiceTranscriptionError.invalidRecording) {
            try VoiceRecordingPolicy.validatedData(at: disguisedURL)
        }
    }

    @Test("Launch cleanup removes only stale Herdr recordings")
    func removesStaleTemporaryRecordings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "herdr-voice-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let stale = directory.appending(path: "herdr-voice-stale.wav")
        let fresh = directory.appending(path: "herdr-voice-fresh.wav")
        let unrelated = directory.appending(path: "other-voice.wav")
        for file in [stale, fresh, unrelated] {
            try Data([0]).write(to: file)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-25 * 60 * 60)],
            ofItemAtPath: stale.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-25 * 60 * 60)],
            ofItemAtPath: unrelated.path
        )

        VoiceRecordingPolicy.removeStaleTemporaryRecordings(in: directory, now: now)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("Request and response preserve the private proxy contract")
    func preservesProxyContract() throws {
        let request = VoiceTranscriptionRequest(
            filename: "ramble.wav",
            mimeType: "audio/wav",
            dataBase64: "UklGRg=="
        )
        let encoded = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        #expect(object["mime_type"] == "audio/wav")
        #expect(object["data_base64"] == "UklGRg==")

        let response = try JSONDecoder().decode(
            VoiceTranscriptionResponse.self,
            from: Data(#"{"ok":true,"text":"hello","backend":"parakeet","language":"en"}"#.utf8)
        )
        #expect(response.text == "hello")
        #expect(response.backend == "parakeet")
    }

    @Test("Private failure falls back to Apple without auto-sending")
    func fallsBackToApple() async throws {
        let result = try await VoiceTranscriptionPipeline.run(
            preferPrivate: true,
            privateTranscription: { throw APIError.streamEnded },
            appleTranscription: {
                VoiceTranscription(
                    text: "Editable transcript",
                    provider: .apple,
                    language: "en",
                    usedFallback: false
                )
            }
        )

        #expect(result.text == "Editable transcript")
        #expect(result.provider == .apple)
        #expect(result.usedFallback)
    }

    @Test("Cancellation never starts a fallback")
    func cancellationStopsPipeline() async {
        let appleWasCalled = AsyncFlag()
        do {
            _ = try await VoiceTranscriptionPipeline.run(
                preferPrivate: true,
                privateTranscription: { throw CancellationError() },
                appleTranscription: {
                    await appleWasCalled.set()
                    return VoiceTranscription(
                        text: "must not happen",
                        provider: .apple,
                        language: nil,
                        usedFallback: false
                    )
                }
            )
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected. Cancellation must not be treated as provider failure.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        let fallbackStarted = await appleWasCalled.value
        #expect(!fallbackStarted)
    }
}

private actor AsyncFlag {
    private(set) var value = false

    func set() { value = true }
}
