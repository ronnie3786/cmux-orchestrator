import AppKit
import Foundation
import UniformTypeIdentifiers
import Testing
@testable import herdr_harness_mac

@Suite("Herdr HUD attachments")
@MainActor
struct HerdrHudAttachmentTests {
    @Test("Dropped image data becomes a durable sendable attachment")
    func imageDataDrop() async throws {
        let provider = NSItemProvider()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(bytes, nil)
            return nil
        }
        let session = makeSession()
        #expect(session.acceptAttachmentDrop([provider]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while session.pendingAttachments.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let attachment = try #require(session.pendingAttachments.first)
        #expect(attachment.isImage)
        #expect(try Data(contentsOf: attachment.url) == bytes)
        session.removeAttachment(attachment.id)
        #expect(!FileManager.default.fileExists(atPath: attachment.url.path))
    }

    @Test("Attachment-only sends retain inline files after the source is removed and history restored")
    func attachmentOnlySubmissionRetainsInlineFile() async throws {
        let source = temporaryURL(named: "notes.txt")
        let bytes = Data("Keep this attachment".utf8)
        try bytes.write(to: source)
        let session = makeSession()
        session.addAttachments([source])
        let attachment = try #require(session.pendingAttachments.first)
        try FileManager.default.removeItem(at: source)
        await session.submit(model: makeDemoModel())
        let exchange = try #require(session.exchanges.last)
        #expect(exchange.status == .completed)
        #expect(exchange.localAttachments == [attachment])
        #expect(exchange.attachments.isEmpty)
        #expect(try Data(contentsOf: attachment.url) == bytes)

        let snapshot = HerdrHudPersistenceSnapshot(thread: session.thread, exchanges: session.exchanges)
        let restored = try JSONDecoder().decode(HerdrHudPersistenceSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.restoredValues().exchanges.last?.localAttachments == [attachment])
        await session.clear(model: makeDemoModel())
        #expect(!FileManager.default.fileExists(atPath: attachment.url.path))
    }

    @Test("Allowed files are accepted and image classification is retained")
    func allowedFilesAreAcceptedAndClassified() throws {
        let textURL = temporaryURL(named: "notes.txt")
        let pdfURL = temporaryURL(named: "report.pdf")
        let imageURL = temporaryURL(named: "photo.png")
        defer {
            try? FileManager.default.removeItem(at: textURL)
            try? FileManager.default.removeItem(at: pdfURL)
            try? FileManager.default.removeItem(at: imageURL)
        }
        try Data("notes".utf8).write(to: textURL)
        try Data("%PDF-1.4".utf8).write(to: pdfURL)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        let session = makeSession()
        session.addAttachments([textURL, pdfURL, imageURL])

        #expect(session.validationError == nil)
        #expect(session.pendingAttachments.map(\.filename) == [
            textURL.lastPathComponent, pdfURL.lastPathComponent, imageURL.lastPathComponent,
        ])
        #expect(session.pendingAttachments.map(\.isImage) == [false, false, true])
    }

    @Test("Unsupported files are rejected")
    func unsupportedFilesAreRejected() throws {
        let url = temporaryURL(named: "unsupported.exe")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x01]).write(to: url)

        let session = makeSession()
        session.addAttachments([url])

        #expect(session.pendingAttachments.isEmpty)
        #expect(session.validationError != nil)
    }

    @Test("The four-file cap remains enforced")
    func enforcesFourFileCap() throws {
        let urls = (0..<5).map { temporaryURL(named: "attachment-\($0).txt") }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        for url in urls {
            try Data([0x01]).write(to: url)
        }

        let session = makeSession()
        session.addAttachments(urls)

        #expect(session.pendingAttachments.count == 4)
        #expect(session.validationError != nil)
    }

    @Test("The aggregate cap remains enforced")
    func enforcesAggregateCap() throws {
        let firstURL = temporaryURL(named: "first.txt")
        let secondURL = temporaryURL(named: "second.pdf")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        try Data(repeating: 0, count: 11 * 1024 * 1024).write(to: firstURL)
        try Data(repeating: 0, count: 11 * 1024 * 1024).write(to: secondURL)

        let session = makeSession()
        session.addAttachments([firstURL, secondURL])

        #expect(session.pendingAttachments.map(\.filename) == [firstURL.lastPathComponent])
        #expect(session.validationError != nil)
    }

    @Test("Only image attachments select a vision model")
    func onlyImageAttachmentsSelectVisionModel() async throws {
        let textURL = temporaryURL(named: "notes.txt")
        let imageURL = temporaryURL(named: "photo.png")
        defer {
            try? FileManager.default.removeItem(at: textURL)
            try? FileManager.default.removeItem(at: imageURL)
        }
        try Data("notes".utf8).write(to: textURL)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        let textSession = makeSession()
        textSession.addAttachments([textURL])
        textSession.draft = "Read these notes"
        await textSession.submit(model: makeDemoModel())
        #expect(textSession.lastHeadlessRunForTesting?.model == nil)

        let imageSession = makeSession()
        imageSession.addAttachments([textURL, imageURL])
        imageSession.draft = "Read these files"
        await imageSession.submit(model: makeDemoModel())
        #expect(imageSession.lastHeadlessRunForTesting?.model == HerdrHudModelRouting.visionModel)
    }

    private func temporaryURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    private func makeDemoModel() -> HerdrAppModel {
        HerdrAppModel(
            arguments: ["HerdrTests", "-HerdrDemoMode"],
            userDefaults: makeDefaults(prefix: "model")
        )
    }

    private func makeSession() -> HerdrHudSession {
        HerdrHudSession(
            userDefaults: makeDefaults(prefix: "session"),
            persistenceURL: temporaryURL(named: "hud-thread.json")
        )
    }

    private func makeDefaults(prefix: String) -> UserDefaults {
        let suiteName = "HerdrHudAttachmentTests.\(prefix).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
