import AVFoundation
import Foundation
import Speech

enum VoiceTranscriptionProvider: String, Sendable {
    case apple = "Apple Speech"
    case parakeet = "Parakeet"
    case server = "Private server"
    case demo = "Demo"
}

struct VoiceTranscription: Equatable, Sendable {
    let text: String
    let provider: VoiceTranscriptionProvider
    let language: String?
    let usedFallback: Bool
}

struct VoiceTranscriptionRequest: Encodable, Sendable {
    let filename: String
    let mimeType: String
    let dataBase64: String

    enum CodingKeys: String, CodingKey {
        case filename
        case mimeType = "mime_type"
        case dataBase64 = "data_base64"
    }
}

struct VoiceTranscriptionResponse: Decodable, Sendable {
    let ok: Bool
    let text: String
    let backend: String
    let language: String?
}

enum VoiceRecordingPolicy {
    static let maximumBytes: Int64 = 20 * 1024 * 1024
    static let maximumDuration: TimeInterval = 10 * 60
    private static let sampleRate: UInt32 = 16_000
    private static let channelCount: UInt16 = 1
    private static let bitsPerSample: UInt16 = 16
    private static let temporaryPrefix = "herdr-voice-"
    private static let staleRecordingAge: TimeInterval = 24 * 60 * 60

    static func validateByteCount(_ byteCount: Int64) throws {
        guard byteCount > 0 else { throw VoiceTranscriptionError.invalidRecording }
        guard byteCount <= maximumBytes else {
            throw VoiceTranscriptionError.recordingTooLarge
        }
    }

    static func validatedData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw VoiceTranscriptionError.invalidRecording
        }
        try validateByteCount(Int64(size))
        guard url.pathExtension.lowercased() == "wav" else {
            throw VoiceTranscriptionError.invalidRecording
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try validateByteCount(Int64(data.count))
        try validateWAV(data)
        return data
    }

    static func makeTemporaryURL(
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = .now
    ) -> URL {
        let timestamp = Int(now.timeIntervalSince1970)
        let filename = "\(temporaryPrefix)\(timestamp)-\(UUID().uuidString.prefix(8)).wav"
        return directory.appending(path: filename)
    }

    static func applyCompleteProtection(to url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #else
        // macOS has no per-file data protection class. The closest equivalent
        // for a temporary recording is owner-only POSIX permissions.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        #endif
    }

    static func removeStaleTemporaryRecordings(
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = .now
    ) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files where file.lastPathComponent.hasPrefix(temporaryPrefix)
            && file.pathExtension.lowercased() == "wav" {
            guard let values = try? file.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ),
            values.isRegularFile == true,
            let modifiedAt = values.contentModificationDate,
            now.timeIntervalSince(modifiedAt) >= staleRecordingAge
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func validateWAV(_ data: Data) throws {
        guard data.count >= 44,
              data.prefix(4) == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8),
              Int(littleEndianUInt32(data, at: 4)) + 8 == data.count
        else { throw VoiceTranscriptionError.invalidRecording }

        var offset = 12
        var format: (UInt16, UInt16, UInt32, UInt32, UInt16, UInt16)?
        var audioByteCount: UInt32?
        while offset + 8 <= data.count {
            let chunkID = data[offset..<(offset + 4)]
            let chunkByteCount = littleEndianUInt32(data, at: offset + 4)
            let payloadStart = offset + 8
            guard chunkByteCount <= UInt32(data.count - payloadStart) else {
                throw VoiceTranscriptionError.invalidRecording
            }
            let payloadEnd = payloadStart + Int(chunkByteCount)
            if chunkID == Data("fmt ".utf8), format == nil {
                guard chunkByteCount >= 16 else { throw VoiceTranscriptionError.invalidRecording }
                format = (
                    littleEndianUInt16(data, at: payloadStart),
                    littleEndianUInt16(data, at: payloadStart + 2),
                    littleEndianUInt32(data, at: payloadStart + 4),
                    littleEndianUInt32(data, at: payloadStart + 8),
                    littleEndianUInt16(data, at: payloadStart + 12),
                    littleEndianUInt16(data, at: payloadStart + 14)
                )
            } else if chunkID == Data("data".utf8), audioByteCount == nil {
                audioByteCount = chunkByteCount
            }
            offset = payloadEnd + Int(chunkByteCount & 1)
        }

        guard offset == data.count,
              let format,
              let audioByteCount,
              audioByteCount > 0
        else { throw VoiceTranscriptionError.invalidRecording }

        let expectedBlockAlignment = channelCount * (bitsPerSample / 8)
        let expectedByteRate = sampleRate * UInt32(expectedBlockAlignment)
        guard format.0 == 1,
              format.1 == channelCount,
              format.2 == sampleRate,
              format.3 == expectedByteRate,
              format.4 == expectedBlockAlignment,
              format.5 == bitsPerSample,
              audioByteCount % UInt32(expectedBlockAlignment) == 0,
              UInt64(audioByteCount) <= UInt64(expectedByteRate) * UInt64(maximumDuration)
        else { throw VoiceTranscriptionError.invalidRecording }
    }

    private static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

enum VoiceTranscriptionError: LocalizedError, Equatable {
    case invalidRecording
    case recordingTooLarge
    case speechPermissionDenied
    case localeUnavailable
    case emptyTranscript
    case privateAndAppleFailed

    var errorDescription: String? {
        switch self {
        case .invalidRecording:
            "The recording could not be read. Record it again and retry."
        case .recordingTooLarge:
            "The recording exceeds the 20 MB transcription limit."
        case .speechPermissionDenied:
            "Speech Recognition access is required for the on-device fallback."
        case .localeUnavailable:
            "Apple Speech does not have a transcription model for this language."
        case .emptyTranscript:
            "No speech was found in the recording."
        case .privateAndAppleFailed:
            "Private transcription and the Apple Speech fallback were both unavailable. Your recording is still here."
        }
    }
}

enum VoiceTranscriptionPipeline {
    static func run(
        preferPrivate: Bool,
        privateTranscription: @Sendable () async throws -> VoiceTranscription,
        appleTranscription: @Sendable () async throws -> VoiceTranscription
    ) async throws -> VoiceTranscription {
        guard preferPrivate else {
            return try await appleTranscription()
        }

        do {
            return try await privateTranscription()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            do {
                let fallback = try await appleTranscription()
                return VoiceTranscription(
                    text: fallback.text,
                    provider: fallback.provider,
                    language: fallback.language,
                    usedFallback: true
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw VoiceTranscriptionError.privateAndAppleFailed
            }
        }
    }
}

enum AppleVoiceTranscriber {
    private enum ChildResult: Sendable {
        case transcript([String])
        case analysisFinished
    }

    static func transcribe(fileURL: URL, locale requestedLocale: Locale = .current) async throws -> String {
        try Task.checkCancellation()
        try await authorizeSpeechRecognition()

        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        else {
            throw VoiceTranscriptionError.localeUnavailable
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try Task.checkCancellation()
            try await installation.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let transcript = try await withThrowingTaskGroup(of: ChildResult.self) { group in
            group.addTask {
                var passages: [String] = []
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    let passage = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !passage.isEmpty { passages.append(passage) }
                }
                return .transcript(passages)
            }
            group.addTask {
                let audioFile = try AVAudioFile(forReading: fileURL)
                if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                    try await analyzer.finalizeAndFinish(through: lastSampleTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                return .analysisFinished
            }

            var passages: [String] = []
            for try await childResult in group {
                if case let .transcript(value) = childResult {
                    passages = value
                }
            }
            return passages.joined(separator: " ")
        }

        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw VoiceTranscriptionError.emptyTranscript }
        return cleaned
    }

    private static func authorizeSpeechRecognition() async throws {
        let status: SFSpeechRecognizerAuthorizationStatus
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorization in
                    continuation.resume(returning: authorization)
                }
            }
        case let current:
            status = current
        }
        guard status == .authorized else {
            throw VoiceTranscriptionError.speechPermissionDenied
        }
    }
}
