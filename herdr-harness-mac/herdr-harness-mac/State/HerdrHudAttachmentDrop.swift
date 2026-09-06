import AppKit
import UniformTypeIdentifiers

extension HerdrHudSession {
    /// Finder files and image data from browsers or screenshot tools share
    /// the same validated, durable attachment import path.
    func acceptAttachmentDrop(_ providers: [NSItemProvider]) -> Bool {
        let supported = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !supported.isEmpty else { return false }
        Task {
            for provider in supported.prefix(Self.maxAttachments) {
                do {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        let data = try await Self.droppedData(provider, type: UTType.fileURL.identifier)
                        guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                            reportAttachmentError("Drop a local file or image into the HUD.")
                            continue
                        }
                        addAttachments([url])
                    } else if let type = provider.registeredTypeIdentifiers.first(where: {
                        UTType($0)?.conforms(to: .image) == true
                    }) {
                        let data = try await Self.droppedData(provider, type: type)
                        guard !data.isEmpty, Int64(data.count) <= AttachmentPolicy.maximumFileBytes else {
                            reportAttachmentError("Images must be between 1 byte and 20 MB.")
                            continue
                        }
                        let ext = UTType(type)?.preferredFilenameExtension ?? "png"
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("Dropped image \(UUID().uuidString).\(ext)")
                        try data.write(to: url, options: .atomic)
                        defer { try? FileManager.default.removeItem(at: url) }
                        addAttachments([url])
                    }
                } catch {
                    reportAttachmentError("Couldn't attach the dropped item: \(error.localizedDescription)")
                }
            }
        }
        return true
    }

    private static func droppedData(_ provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}
