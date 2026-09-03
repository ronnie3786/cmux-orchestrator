import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("HUD result artifact presentation")
struct HerdrHudResultArtifactPresentationTests {
    @Test("File families map to distinct extensible HUD categories", arguments: [
        ("report.pdf", "application/octet-stream", HerdrHudResultArtifactCategory.pdf),
        ("prototype.html", "text/html", .webPage),
        ("demo.mp4", "video/mp4", .video),
        ("cover.png", "image/png", .image),
        ("briefing.m4a", "audio/mp4", .audio),
        ("metrics.xlsx", "application/octet-stream", .spreadsheet),
        ("launch.key", "application/octet-stream", .presentation),
        ("client.swift", "text/x-swift", .sourceCode),
        ("bundle.zip", "application/zip", .archive),
        ("notes.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", .document),
        ("opaque.data", "application/octet-stream", .generic),
    ])
    func classifiesFileFamilies(
        filename: String,
        contentType: String,
        expected: HerdrHudResultArtifactCategory
    ) {
        #expect(category(filename: filename, contentType: contentType) == expected)
    }

    @Test("Links use the link presentation regardless of their URL suffix")
    func classifiesLink() {
        let artifact = AgentResultArtifact(
            id: "link",
            originType: .agentRun,
            originID: "run",
            kind: .link,
            title: "Review deployment",
            createdAt: HerdrTimestamp.string(from: .now),
            url: URL(string: "https://example.com/report.pdf")
        )
        .stamped(machineID: "m1")

        #expect(HerdrHudResultArtifactCategory(artifact: artifact) == .link)
    }

    @Test("Every category carries complete presentation metadata")
    func presentationMetadataIsComplete() {
        for category in HerdrHudResultArtifactCategory.allCases {
            #expect(!category.symbol.isEmpty)
            #expect(!category.compactLabel.isEmpty)
            #expect(!category.privacyLabel.isEmpty)
            #expect(!category.rawValue.isEmpty)
        }
        #expect(HerdrHudResultArtifactCategory.pdf.privacyLabel == "PDF result")
        #expect(HerdrHudResultArtifactCategory.video.privacyLabel == "Video result")
    }

    @Test("Hidden HUD titles also redact filenames and paths from native open failures")
    func hiddenTitlesRedactFailureDetails() {
        let sensitive = "Could not open /private/cache/Acquisition-Terms.pdf"
        #expect(
            HerdrHudResultArtifactPrivacy.visibleFailureDetail(
                sensitive,
                revealsSensitiveDetails: false
            ) == nil
        )
        #expect(
            HerdrHudResultArtifactPrivacy.visibleFailureDetail(
                sensitive,
                revealsSensitiveDetails: true
            ) == sensitive
        )
    }

    private func category(
        filename: String,
        contentType: String
    ) -> HerdrHudResultArtifactCategory {
        let artifact = AgentResultArtifact(
            id: filename,
            originType: .pane,
            originID: "pane",
            kind: .file,
            title: filename,
            filename: filename,
            contentType: contentType,
            byteSize: 1,
            createdAt: HerdrTimestamp.string(from: .now),
            downloadPath: "/api/v1/result-artifacts/\(filename)/content"
        )
        .stamped(machineID: "m1")
        return HerdrHudResultArtifactCategory(artifact: artifact)
    }
}
