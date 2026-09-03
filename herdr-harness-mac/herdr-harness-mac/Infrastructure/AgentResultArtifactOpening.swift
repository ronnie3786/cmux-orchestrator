import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AgentResultArtifactOpenedLedger {
    struct RetentionPolicy: Sendable, Equatable {
        /// Canonical per-machine inventories perform the normal tombstone GC.
        /// The standard policy therefore does not age or globally cap handled
        /// IDs while a server can still retain the corresponding artifact.
        static let standard = RetentionPolicy(
            maximumEntryCount: .max,
            maximumAge: .greatestFiniteMagnitude
        )

        let maximumEntryCount: Int
        let maximumAge: TimeInterval

        init(maximumEntryCount: Int, maximumAge: TimeInterval) {
            self.maximumEntryCount = max(0, maximumEntryCount)
            self.maximumAge = max(0, maximumAge)
        }
    }

    private struct StoredLedger: Codable {
        struct Entry: Codable {
            let presentationID: String
            let openedAt: TimeInterval
        }

        let version: Int
        let entries: [Entry]
    }

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let retentionPolicy: RetentionPolicy
    private let now: @MainActor () -> Date
    private var openedAtByPresentationID: [String: TimeInterval]

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "herdr.resultArtifacts.opened.v1",
        retentionPolicy: RetentionPolicy = .standard,
        now: @escaping @MainActor () -> Date = { .now }
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.retentionPolicy = retentionPolicy
        self.now = now

        let referenceDate = now()
        if let data = userDefaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode(StoredLedger.self, from: data),
           stored.version == 1 {
            openedAtByPresentationID = Dictionary(
                stored.entries.map { ($0.presentationID, $0.openedAt) },
                uniquingKeysWith: max
            )
        } else {
            // v1 originally stored a bare string array. Treat migrated IDs as
            // freshly opened so an upgrade never reveals a result the user has
            // already dismissed.
            openedAtByPresentationID = Dictionary(
                (userDefaults.stringArray(forKey: storageKey) ?? [])
                    .map { ($0, referenceDate.timeIntervalSince1970) },
                uniquingKeysWith: max
            )
        }
        prune(referenceDate: referenceDate)
        persist()
    }

    func contains(_ presentationID: String) -> Bool {
        let referenceDate = now()
        if prune(referenceDate: referenceDate) { persist() }
        return openedAtByPresentationID[presentationID] != nil
    }

    func markOpened(_ presentationID: String) {
        guard !presentationID.isEmpty else { return }
        let referenceDate = now()
        openedAtByPresentationID[presentationID] = referenceDate.timeIntervalSince1970
        prune(referenceDate: referenceDate)
        persist()
    }

    /// Drops handled IDs only after a successful canonical list proves they
    /// no longer exist on that machine. Offline machines keep their history,
    /// preventing old but server-retained outputs from resurfacing.
    func reconcile(
        machineID: String,
        activePresentationIDs: Set<String>
    ) {
        let prefix = "\(machineID)\(MachineScopedID.separator)"
        let original = openedAtByPresentationID
        openedAtByPresentationID = openedAtByPresentationID.filter { presentationID, _ in
            !presentationID.hasPrefix(prefix) || activePresentationIDs.contains(presentationID)
        }
        if openedAtByPresentationID != original { persist() }
    }

    @discardableResult
    private func prune(referenceDate: Date) -> Bool {
        let original = openedAtByPresentationID
        let cutoff = referenceDate.timeIntervalSince1970 - retentionPolicy.maximumAge
        let retained = openedAtByPresentationID
            .filter { $0.value >= cutoff }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .prefix(retentionPolicy.maximumEntryCount)
        openedAtByPresentationID = Dictionary(
            uniqueKeysWithValues: retained.map { ($0.key, $0.value) }
        )
        return original != openedAtByPresentationID
    }

    private func persist() {
        let entries = openedAtByPresentationID
            .map { StoredLedger.Entry(presentationID: $0.key, openedAt: $0.value) }
            .sorted {
                if $0.openedAt != $1.openedAt { return $0.openedAt > $1.openedAt }
                return $0.presentationID < $1.presentationID
            }
        let stored = StoredLedger(version: 1, entries: entries)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}

struct AgentResultArtifactCache: Sendable {
    struct RetentionPolicy: Sendable, Equatable {
        static let standard = RetentionPolicy(
            maximumFileCount: 256,
            maximumByteCount: 1 * 1_024 * 1_024 * 1_024,
            maximumAge: 30 * 24 * 60 * 60
        )

        let maximumFileCount: Int
        let maximumByteCount: Int64
        let maximumAge: TimeInterval

        init(maximumFileCount: Int, maximumByteCount: Int64, maximumAge: TimeInterval) {
            self.maximumFileCount = max(0, maximumFileCount)
            self.maximumByteCount = max(0, maximumByteCount)
            self.maximumAge = max(0, maximumAge)
        }
    }

    struct CleanupReport: Sendable, Equatable {
        let removedPaths: [String]
        let remainingFileCount: Int
        let remainingByteCount: Int64
    }

    private struct CacheFile {
        let url: URL
        let modifiedAt: Date
        let byteCount: Int64
    }

    enum CacheError: LocalizedError, Sendable {
        case unstampedArtifact
        case notAFile
        case unsafeDestination

        var errorDescription: String? {
            switch self {
            case .unstampedArtifact:
                "This result is missing its source machine."
            case .notAFile:
                "Only file results can be placed in the artifact cache."
            case .unsafeDestination:
                "Herdr could not create a safe local path for this result."
            }
        }
    }

    let rootURL: URL
    let retentionPolicy: RetentionPolicy

    init(
        rootURL: URL = Self.defaultRootURL(),
        retentionPolicy: RetentionPolicy = .standard
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.retentionPolicy = retentionPolicy
    }

    func destinationURL(for artifact: AgentResultArtifact) throws -> URL {
        guard artifact.kind == .file else { throw CacheError.notAFile }
        guard !artifact.machineID.isEmpty, !artifact.rawID.isEmpty else {
            throw CacheError.unstampedArtifact
        }

        let presentationDirectory = "result-\(Self.fileSystemToken(artifact.id))"
        let destination = rootURL
            .appending(path: presentationDirectory, directoryHint: .isDirectory)
            .appending(path: Self.safeFilename(for: artifact), directoryHint: .notDirectory)
            .standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard destination.path.hasPrefix(rootPath), destination.deletingLastPathComponent() != rootURL else {
            throw CacheError.unsafeDestination
        }
        return destination
    }

    /// Creates and validates the two writable cache directories without ever
    /// accepting a symlink at either app-owned component. The system caches
    /// directory above `rootURL` remains the trusted anchor.
    func prepareDestinationURL(
        for artifact: AgentResultArtifact,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = try destinationURL(for: artifact)
        try ensureSafeDirectory(
            rootURL,
            createWithIntermediateDirectories: true,
            fileManager: fileManager
        )
        let presentationDirectory = destination.deletingLastPathComponent().standardizedFileURL
        guard presentationDirectory.deletingLastPathComponent().standardizedFileURL == rootURL else {
            throw CacheError.unsafeDestination
        }
        try ensureSafeDirectory(
            presentationDirectory,
            createWithIntermediateDirectories: false,
            fileManager: fileManager
        )
        return destination
    }

    static func safeFilename(for artifact: AgentResultArtifact) -> String {
        let supplied = artifact.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = artifact.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = supplied.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        let leaf = (candidate as NSString).lastPathComponent

        let allowedPunctuation = CharacterSet(charactersIn: ".-_ ()[]")
        let allowed = CharacterSet.alphanumerics.union(allowedPunctuation)
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(min(leaf.unicodeScalars.count, 120))
        var previousWasReplacement = false
        for scalar in leaf.unicodeScalars.prefix(120) {
            if allowed.contains(scalar), !CharacterSet.controlCharacters.contains(scalar) {
                scalars.append(scalar)
                previousWasReplacement = false
            } else if !previousWasReplacement {
                scalars.append("-")
                previousWasReplacement = true
            }
        }

        var result = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if result.isEmpty || result == "." || result == ".." { result = "artifact" }

        if (result as NSString).pathExtension.isEmpty,
           let contentType = artifact.contentType,
           let preferredExtension = UTType(mimeType: contentType)?.preferredFilenameExtension {
            result += ".\(preferredExtension)"
        }
        return result
    }

    @discardableResult
    func cleanup(
        fileManager: FileManager = .default,
        now: Date = .now,
        protecting protectedURLs: Set<URL> = []
    ) throws -> CleanupReport {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return CleanupReport(removedPaths: [], remainingFileCount: 0, remainingByteCount: 0)
        }
        let rootValues = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CacheError.unsafeDestination
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else {
            return CleanupReport(removedPaths: [], remainingFileCount: 0, remainingByteCount: 0)
        }

        var files: [CacheFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { continue }
            files.append(CacheFile(
                url: url.standardizedFileURL,
                modifiedAt: values.contentModificationDate ?? values.creationDate ?? .distantPast,
                byteCount: Int64(max(0, values.fileSize ?? 0))
            ))
        }

        let protectedPaths = Set(protectedURLs.map { $0.standardizedFileURL.path })
        let protectedDirectoryPaths = Set(
            protectedURLs.map { $0.standardizedFileURL.deletingLastPathComponent().path }
        )
        func isProtected(_ file: CacheFile) -> Bool {
            protectedPaths.contains(file.url.path)
                || protectedDirectoryPaths.contains(file.url.deletingLastPathComponent().path)
        }
        let cutoff = now.addingTimeInterval(-retentionPolicy.maximumAge)
        var removalPaths = Set(
            files
                .filter { $0.modifiedAt < cutoff && !isProtected($0) }
                .map { $0.url.path }
        )
        var remaining = files.filter { !removalPaths.contains($0.url.path) }
        var remainingBytes = Self.totalBytes(remaining)
        var remainingCount = remaining.count
        let evictionOrder = remaining
            .filter { !isProtected($0) }
            .sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
                return $0.url.path > $1.url.path
            }

        for file in evictionOrder {
            guard remainingCount > retentionPolicy.maximumFileCount
                    || remainingBytes > retentionPolicy.maximumByteCount
            else { break }
            guard removalPaths.insert(file.url.path).inserted else { continue }
            remainingCount -= 1
            remainingBytes = max(0, remainingBytes - file.byteCount)
        }

        let orderedRemovals = files
            .filter { removalPaths.contains($0.url.path) }
            .sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
                return $0.url.path < $1.url.path
            }
        var removedPaths: [String] = []
        for file in orderedRemovals {
            try fileManager.removeItem(at: file.url)
            removedPaths.append(file.url.path)
            removeEmptyParent(of: file.url, fileManager: fileManager)
        }

        let removedPathSet = Set(removedPaths)
        remaining = files.filter { !removedPathSet.contains($0.url.path) }
        return CleanupReport(
            removedPaths: removedPaths,
            remainingFileCount: remaining.count,
            remainingByteCount: Self.totalBytes(remaining)
        )
    }

    func markAccessed(
        _ url: URL,
        at date: Date,
        fileManager: FileManager = .default
    ) throws {
        let standardized = url.standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard standardized.path.hasPrefix(rootPath) else { throw CacheError.unsafeDestination }
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: standardized.path)
    }

    private func removeEmptyParent(of fileURL: URL, fileManager: FileManager) {
        let parent = fileURL.deletingLastPathComponent().standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard parent != rootURL, parent.path.hasPrefix(rootPath),
              let contents = try? fileManager.contentsOfDirectory(atPath: parent.path),
              contents.isEmpty
        else { return }
        try? fileManager.removeItem(at: parent)
    }

    private func ensureSafeDirectory(
        _ directory: URL,
        createWithIntermediateDirectories: Bool,
        fileManager: FileManager
    ) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: createWithIntermediateDirectories
            )
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL
        else { throw CacheError.unsafeDestination }
    }

    private static func totalBytes(_ files: [CacheFile]) -> Int64 {
        files.reduce(into: Int64(0)) { total, file in
            let (sum, overflow) = total.addingReportingOverflow(file.byteCount)
            total = overflow ? .max : sum
        }
    }

    private static func fileSystemToken(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func defaultRootURL() -> URL {
        let baseURL = (try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return baseURL
            .appending(path: "dev.ronnierocha.herdr-harness", directoryHint: .isDirectory)
            .appending(path: "PresentedResults", directoryHint: .isDirectory)
    }
}

@MainActor
final class AgentResultArtifactOpener {
    typealias OpenURL = @MainActor (URL) -> Bool
    typealias DownloadFile = @MainActor (URL) async throws -> Void
    typealias Now = @MainActor () -> Date

    enum OpenError: LocalizedError, Sendable {
        case invalidLink
        case missingDownload
        case invalidDownloadedFile
        case sizeMismatch(expected: Int64, actual: Int64)
        case applicationUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidLink:
                "This result link is not a valid HTTP or HTTPS address."
            case .missingDownload:
                "Herdr could not retrieve this result from its source machine."
            case .invalidDownloadedFile:
                "The downloaded result was not a regular file."
            case let .sizeMismatch(expected, actual):
                "The downloaded result was incomplete (expected \(expected) bytes, received \(actual))."
            case .applicationUnavailable:
                "macOS could not find an application that can open this result."
            }
        }
    }

    private let cache: AgentResultArtifactCache
    private let ledger: AgentResultArtifactOpenedLedger
    private let fileManager: FileManager
    private let openURL: OpenURL
    private let now: Now
    private var activeCacheURLCounts: [URL: Int] = [:]

    init(
        cache: AgentResultArtifactCache,
        ledger: AgentResultArtifactOpenedLedger,
        fileManager: FileManager = .default,
        openURL: @escaping OpenURL = { NSWorkspace.shared.open($0) },
        now: @escaping Now = { .now }
    ) {
        self.cache = cache
        self.ledger = ledger
        self.fileManager = fileManager
        self.openURL = openURL
        self.now = now
        _ = try? cache.cleanup(fileManager: fileManager, now: now())
    }

    /// Returns the URL handed to Launch Services. The ledger advances only
    /// after Launch Services accepts the request, so failed results remain
    /// visible and retryable.
    @discardableResult
    func open(
        _ artifact: AgentResultArtifact,
        downloadFile: DownloadFile? = nil
    ) async throws -> URL {
        let localURL: URL
        var protectedCacheURL: URL?
        defer {
            if let protectedCacheURL {
                try? cleanupCache()
                unprotectCacheURL(protectedCacheURL)
            }
        }
        switch artifact.kind {
        case .link:
            try? cleanupCache()
            guard let url = artifact.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false
            else { throw OpenError.invalidLink }
            localURL = url
        case .file:
            let destination = try cache.prepareDestinationURL(
                for: artifact,
                fileManager: fileManager
            )
            protectCacheURL(destination)
            protectedCacheURL = destination
            try? cleanupCache()
            if fileManager.fileExists(atPath: destination.path),
               !Self.isValidFile(destination, artifact: artifact, fileManager: fileManager) {
                if activeCacheURLCounts[destination.standardizedFileURL, default: 0] > 1 {
                    try Self.validateFile(destination, artifact: artifact, fileManager: fileManager)
                }
                try fileManager.removeItem(at: destination)
            }
            if !fileManager.fileExists(atPath: destination.path) {
                guard let downloadFile else { throw OpenError.missingDownload }
                try await downloadFile(destination)
            }
            try Self.validateFile(destination, artifact: artifact, fileManager: fileManager)
            localURL = destination
        }

        guard openURL(localURL) else { throw OpenError.applicationUnavailable }
        if artifact.kind == .file {
            try? cache.markAccessed(localURL, at: now(), fileManager: fileManager)
        }
        ledger.markOpened(artifact.id)
        return localURL
    }

    private func cleanupCache() throws {
        try cache.cleanup(
            fileManager: fileManager,
            now: now(),
            protecting: Set(activeCacheURLCounts.keys)
        )
    }

    private func protectCacheURL(_ url: URL) {
        let standardized = url.standardizedFileURL
        activeCacheURLCounts[standardized, default: 0] += 1
    }

    private func unprotectCacheURL(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard let count = activeCacheURLCounts[standardized] else { return }
        if count <= 1 {
            activeCacheURLCounts.removeValue(forKey: standardized)
        } else {
            activeCacheURLCounts[standardized] = count - 1
        }
    }

    private static func isValidFile(
        _ url: URL,
        artifact: AgentResultArtifact,
        fileManager: FileManager
    ) -> Bool {
        do {
            try validateFile(url, artifact: artifact, fileManager: fileManager)
            return true
        } catch {
            return false
        }
    }

    private static func validateFile(
        _ url: URL,
        artifact: AgentResultArtifact,
        fileManager: FileManager
    ) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw OpenError.invalidDownloadedFile
        }
        if let expected = artifact.byteSize,
           let size = values.fileSize,
           Int64(size) != expected {
            throw OpenError.sizeMismatch(expected: expected, actual: Int64(size))
        }
        _ = fileManager
    }
}
