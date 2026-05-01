import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AttachmentTray: View {
    let attachments: [TerminalAttachment]
    let removeAction: (TerminalAttachment) -> Void
    let retryAction: (TerminalAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(
                        attachment: attachment,
                        removeAction: {
                            removeAction(attachment)
                        },
                        retryAction: {
                            retryAction(attachment)
                        }
                    )
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

struct AttachmentChip: View {
    let attachment: TerminalAttachment
    let removeAction: () -> Void
    let retryAction: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 170, alignment: .leading)

                Text(statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }

            if attachment.status == .uploading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.82))
            } else if attachment.status == .failed {
                Button {
                    HarnessHaptics.inputCTA()
                    retryAction()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Retry attachment upload")
            }

            Button {
                HarnessHaptics.inputCTA()
                removeAction()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.62))
            .accessibilityLabel("Remove attachment")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .frame(height: 52)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        }
    }

    private var systemImage: String {
        let ext = attachment.displayName.split(separator: ".").last.map { String($0).lowercased() } ?? ""
        if ["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(ext) {
            return "photo"
        }
        if ["m4a", "mp3", "wav", "aac", "caf"].contains(ext) {
            return "waveform"
        }
        if ext == "pdf" {
            return "doc.richtext"
        }
        if ["zip", "gz", "tar"].contains(ext) {
            return "archivebox"
        }
        return "doc"
    }

    private var statusText: String {
        switch attachment.status {
        case .uploading:
            return "Uploading"
        case .uploaded:
            return "Added"
        case .failed:
            return attachment.error ?? "Upload failed"
        }
    }

    private var iconColor: Color {
        switch attachment.status {
        case .failed:
            return .red.opacity(0.86)
        case .uploaded:
            return .green.opacity(0.88)
        case .uploading:
            return Color.accentColor
        }
    }

    private var statusColor: Color {
        switch attachment.status {
        case .failed:
            return .red.opacity(0.82)
        case .uploaded:
            return .green.opacity(0.78)
        case .uploading:
            return .white.opacity(0.52)
        }
    }

    private var borderColor: Color {
        switch attachment.status {
        case .failed:
            return .red.opacity(0.35)
        case .uploaded:
            return .green.opacity(0.30)
        case .uploading:
            return .white.opacity(0.16)
        }
    }
}
