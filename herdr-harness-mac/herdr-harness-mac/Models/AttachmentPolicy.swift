import Foundation

enum AttachmentPolicy {
    static let maximumCount = 10
    static let maximumFileBytes: Int64 = 20 * 1024 * 1024
    static let maximumAggregateBytes: Int64 = 40 * 1024 * 1024

    static func validateCount(existingCount: Int, incomingCount: Int) throws {
        guard incomingCount > 0 else { return }
        guard existingCount >= 0, incomingCount >= 0 else {
            throw AttachmentPolicyError.tooManyFiles(maximum: maximumCount)
        }
        let (totalCount, overflow) = existingCount.addingReportingOverflow(incomingCount)
        guard !overflow, totalCount <= maximumCount else {
            throw AttachmentPolicyError.tooManyFiles(maximum: maximumCount)
        }
    }

    static func validateFile(named filename: String, byteCount: Int64) throws {
        guard byteCount > 0 else {
            throw AttachmentPolicyError.emptyFile(filename: filename)
        }
        guard byteCount <= maximumFileBytes else {
            throw AttachmentPolicyError.fileTooLarge(
                filename: filename,
                maximumBytes: maximumFileBytes
            )
        }
    }

    static func validateAggregate(existingBytes: Int64, incomingBytes: Int64) throws {
        guard existingBytes >= 0,
              incomingBytes >= 0,
              existingBytes <= maximumAggregateBytes - incomingBytes
        else {
            throw AttachmentPolicyError.aggregateTooLarge(maximumBytes: maximumAggregateBytes)
        }
    }

    static func validate(
        existingAttachments: [TerminalAttachment],
        incomingCandidates: [AttachmentCandidate]
    ) throws {
        try validateCount(
            existingCount: existingAttachments.count,
            incomingCount: incomingCandidates.count
        )

        var incomingBytes: Int64 = 0
        for candidate in incomingCandidates {
            try validateFile(named: candidate.filename, byteCount: candidate.byteCount)
            let (sum, overflow) = incomingBytes.addingReportingOverflow(candidate.byteCount)
            guard !overflow else {
                throw AttachmentPolicyError.aggregateTooLarge(maximumBytes: maximumAggregateBytes)
            }
            incomingBytes = sum
        }

        let existingBytes = existingAttachments.reduce(into: Int64(0)) { total, attachment in
            let (sum, overflow) = total.addingReportingOverflow(attachment.byteCount)
            total = overflow ? Int64.max : sum
        }
        try validateAggregate(existingBytes: existingBytes, incomingBytes: incomingBytes)
    }

    static func candidate(
        for url: URL,
        ownership: AttachmentSourceOwnership
    ) throws -> AttachmentCandidate {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw AttachmentPolicyError.unreadableFileSize(filename: url.lastPathComponent)
        }

        let byteCount = Int64(fileSize)
        try validateFile(named: url.lastPathComponent, byteCount: byteCount)
        return AttachmentCandidate(
            sourceURL: url,
            filename: url.lastPathComponent,
            byteCount: byteCount,
            ownership: ownership
        )
    }
}

struct AttachmentCandidate: Equatable, Sendable {
    let sourceURL: URL
    let filename: String
    let byteCount: Int64
    let ownership: AttachmentSourceOwnership
}

enum AttachmentPolicyError: LocalizedError, Equatable, Sendable {
    case tooManyFiles(maximum: Int)
    case emptyFile(filename: String)
    case fileTooLarge(filename: String, maximumBytes: Int64)
    case aggregateTooLarge(maximumBytes: Int64)
    case unreadableFileSize(filename: String)

    var errorDescription: String? {
        switch self {
        case let .tooManyFiles(maximum):
            "Attach up to \(maximum) files at a time."
        case let .emptyFile(filename):
            "\(filename) is empty and cannot be attached."
        case let .fileTooLarge(filename, maximumBytes):
            "\(filename) is larger than the \(Self.megabytes(maximumBytes)) MB file limit."
        case let .aggregateTooLarge(maximumBytes):
            "Attachments can total up to \(Self.megabytes(maximumBytes)) MB per message."
        case let .unreadableFileSize(filename):
            "Herdr could not determine the size of \(filename)."
        }
    }

    private static func megabytes(_ bytes: Int64) -> Int64 {
        bytes / (1024 * 1024)
    }
}
