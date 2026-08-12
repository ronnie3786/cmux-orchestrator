import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Attachment resource policy")
struct AttachmentPolicyTests {
    @Test("Count and aggregate budgets are enforced before upload")
    func enforcesBatchBudgets() throws {
        let existing = [
            attachment(byteCount: 20 * 1024 * 1024),
            attachment(byteCount: 20 * 1024 * 1024),
        ]
        let candidate = AttachmentCandidate(
            sourceURL: URL(filePath: "/tmp/one-byte.txt"),
            filename: "one-byte.txt",
            byteCount: 1,
            ownership: .userSelected
        )

        #expect(
            capturePolicyError {
                try AttachmentPolicy.validate(
                    existingAttachments: existing,
                    incomingCandidates: [candidate]
                )
            } == .aggregateTooLarge(maximumBytes: AttachmentPolicy.maximumAggregateBytes)
        )

        #expect(
            capturePolicyError {
                try AttachmentPolicy.validateCount(
                    existingCount: AttachmentPolicy.maximumCount - 1,
                    incomingCount: 2
                )
            } == .tooManyFiles(maximum: AttachmentPolicy.maximumCount)
        )
    }

    @Test("Each attachment is checked before its data is read")
    func enforcesPerFileBudget() {
        #expect(
            capturePolicyError {
                try AttachmentPolicy.validateFile(
                    named: "oversized.mov",
                    byteCount: AttachmentPolicy.maximumFileBytes + 1
                )
            } == .fileTooLarge(
                filename: "oversized.mov",
                maximumBytes: AttachmentPolicy.maximumFileBytes
            )
        )

        #expect(
            capturePolicyError {
                try AttachmentPolicy.validateFile(named: "empty.txt", byteCount: 0)
            } == .emptyFile(filename: "empty.txt")
        )
    }

    @Test("Cleanup deletes app-owned sources and preserves selected originals")
    func cleansOnlyAppOwnedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "herdr-attachment-policy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let temporaryPhoto = directory.appending(path: "herdr-photo.jpg")
        let selectedOriginal = directory.appending(path: "selected-original.txt")
        try Data([0x01]).write(to: temporaryPhoto)
        try Data([0x02]).write(to: selectedOriginal)

        attachment(
            sourceURL: temporaryPhoto,
            byteCount: 1,
            ownership: .appTemporary
        ).removeSourceFileIfOwned()
        attachment(
            sourceURL: selectedOriginal,
            byteCount: 1,
            ownership: .userSelected
        ).removeSourceFileIfOwned()

        #expect(!FileManager.default.fileExists(atPath: temporaryPhoto.path))
        #expect(FileManager.default.fileExists(atPath: selectedOriginal.path))
    }

    private func attachment(
        sourceURL: URL = URL(filePath: "/tmp/attachment.txt"),
        byteCount: Int64,
        ownership: AttachmentSourceOwnership = .userSelected
    ) -> TerminalAttachment {
        TerminalAttachment(
            id: UUID(),
            filename: sourceURL.lastPathComponent,
            sourceURL: sourceURL,
            byteCount: byteCount,
            sourceOwnership: ownership,
            status: .uploading,
            uploaded: nil,
            error: nil
        )
    }

    private func capturePolicyError(_ operation: () throws -> Void) -> AttachmentPolicyError? {
        do {
            try operation()
            return nil
        } catch let error as AttachmentPolicyError {
            return error
        } catch {
            return nil
        }
    }
}
