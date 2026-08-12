import SwiftUI

struct ComposerAttachmentTray: View {
    let attachments: [TerminalAttachment]
    let retry: (TerminalAttachment) -> Void
    let remove: (TerminalAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ComposerAttachmentChip(
                        attachment: attachment,
                        retry: { retry(attachment) },
                        remove: { remove(attachment) }
                    )
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Attachments")
    }
}

private struct ComposerAttachmentChip: View {
    let attachment: TerminalAttachment
    let retry: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: fileIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayName)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .leading)

                Text(statusText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }

            statusAccessory

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(HerdrTheme.mist)
            .accessibilityLabel("Remove \(attachment.displayName)")
        }
        .padding(.leading, 11)
        .padding(.trailing, 2)
        .padding(.vertical, 4)
        .frame(minHeight: 52)
        .background(HerdrTheme.elevated)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
    }

    @ViewBuilder
    private var statusAccessory: some View {
        switch attachment.status {
        case .uploading:
            ProgressView()
                .controlSize(.small)
                .tint(HerdrTheme.accent)
                .accessibilityLabel("Uploading")

        case .uploaded:
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(HerdrTheme.success)
                .accessibilityLabel("Ready")

        case .failed:
            Button(action: retry) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.bold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(HerdrTheme.alert)
            .accessibilityLabel("Retry \(attachment.displayName)")
        }
    }

    private var statusText: String {
        switch attachment.status {
        case .uploading:
            return "uploading"
        case .uploaded:
            return "attached"
        case .failed:
            let message = attachment.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return message.isEmpty ? "upload failed" : message
        }
    }

    private var statusColor: Color {
        switch attachment.status {
        case .uploading:
            HerdrTheme.accent
        case .uploaded:
            HerdrTheme.success
        case .failed:
            HerdrTheme.alert
        }
    }

    private var borderColor: Color {
        switch attachment.status {
        case .uploading:
            HerdrTheme.accent.opacity(0.5)
        case .uploaded:
            HerdrTheme.success.opacity(0.45)
        case .failed:
            HerdrTheme.alert.opacity(0.55)
        }
    }

    private var fileIcon: String {
        let fileExtension = attachment.displayName
            .split(separator: ".")
            .last
            .map { String($0).lowercased() } ?? ""

        if ["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(fileExtension) {
            return "photo"
        }
        if ["m4a", "mp3", "wav", "aac", "caf"].contains(fileExtension) {
            return "waveform"
        }
        if fileExtension == "pdf" {
            return "doc.richtext"
        }
        if ["zip", "gz", "tar"].contains(fileExtension) {
            return "archivebox"
        }
        return "doc.text"
    }
}
