import AppKit
import CoreGraphics
import ImageIO
import SwiftUI

struct HerdrHudAttachmentChipView: View {
    let attachment: HerdrHudAttachment
    let remove: () -> Void
    @State private var thumbnailImage: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            thumbnail
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.filename)
                    .herdrFont(.caption2, monospaced: true)
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Int64(attachment.byteCount).formatted(.byteCount(style: .file)))
                    .herdrFont(.caption2, monospaced: true)
                    .foregroundStyle(HerdrTheme.muted)
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(HerdrTheme.muted)
                    .herdrHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.filename)")
        }
        .padding(.leading, 5)
        .padding(.top, 5)
        .padding(.bottom, 5)
        .padding(.trailing, 2)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .accessibilityIdentifier("hud-attachment-\(attachment.filename)")
        .task(id: attachment.id) {
            guard attachment.isImage else { return }
            guard let cgImage = await (Task.detached(priority: .utility) {
                Self.loadThumbnail(url: attachment.url)
            }.value) else { return }
            thumbnailImage = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumbnailImage {
            Image(nsImage: thumbnailImage)
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        } else {
            Image(
                systemName: attachment.isImage
                    ? "photo"
                    : Self.symbolName(forExtension: URL(fileURLWithPath: attachment.filename).pathExtension)
            )
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.muted)
                .frame(width: 28, height: 28)
                .background(HerdrTheme.surface, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        }
    }

    private static func symbolName(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "pdf":
            "doc.richtext"
        case "csv", "tsv":
            "tablecells"
        case "json", "yaml", "yml", "xml":
            "curlybraces"
        case "txt", "md", "markdown", "rtf", "log", "swift", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "rb", "go", "rs", "java", "kt", "kts", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "php", "sh", "bash", "zsh", "sql", "gradle", "patch", "diff":
            "doc.text"
        default:
            "doc"
        }
    }

    nonisolated private static func loadThumbnail(url: URL) -> CGImage? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 56,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
