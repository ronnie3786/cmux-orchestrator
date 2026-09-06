import AppKit
import ImageIO
import SwiftUI

struct HerdrHudSentAttachmentView: View {
    let attachment: HerdrHudAttachment
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: openAttachment) {
            VStack(alignment: .leading, spacing: 5) {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 150)
                        .clipShape(.rect(cornerRadius: 7))
                }
                Label(attachment.filename, systemImage: attachment.isImage ? "photo" : "doc")
                    .herdrFont(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(Int64(attachment.byteCount).formatted(.byteCount(style: .file)))
                    .herdrFont(.caption2)
                    .foregroundStyle(HerdrTheme.muted)
            }
            .foregroundStyle(HerdrTheme.mist)
            .padding(8)
            .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open attachment: \(attachment.filename)")
        .task(id: attachment.id) { await loadThumbnail() }
    }

    private func openAttachment() {
        NSWorkspace.shared.open(attachment.url)
    }

    private func loadThumbnail() async {
        guard attachment.isImage else { return }
        let url = attachment.url
        let image = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 440,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard !Task.isCancelled, let image else { return }
        thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
