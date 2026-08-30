import AppKit
import CoreGraphics
import ImageIO
import SwiftUI

struct HerdrHudAttachmentChipView: View {
    let attachment: HerdrHudImageAttachment
    let remove: () -> Void
    @State private var thumbnailImage: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            thumbnail
            Text(attachment.filename)
                .herdrFont(.caption2, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(HerdrTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.filename)")
        }
        .padding(5)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .accessibilityIdentifier("hud-attachment-\(attachment.filename)")
        .task(id: attachment.id) {
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
            Image(systemName: "photo")
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.muted)
                .frame(width: 28, height: 28)
                .background(HerdrTheme.surface, in: .rect(cornerRadius: HerdrTheme.compactRadius))
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
