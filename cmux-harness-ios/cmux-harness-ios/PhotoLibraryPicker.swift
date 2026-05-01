import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PhotoImportSummary {
    var urls: [URL] = []
    var failedCount = 0
    var oversizedCount = 0

    static let empty = PhotoImportSummary()

    var warningMessage: String? {
        var messages: [String] = []
        if oversizedCount > 0 {
            messages.append(oversizedCount == 1 ? "Photo exceeds 20 MB limit" : "\(oversizedCount) photos exceed 20 MB limit")
        }
        if failedCount > 0 {
            messages.append(failedCount == 1 ? "Selected photo could not be loaded" : "\(failedCount) selected photos could not be loaded")
        }
        return messages.isEmpty ? nil : messages.joined(separator: ". ")
    }
}

enum PhotoImportError: LocalizedError {
    case unreadablePhoto

    var errorDescription: String? {
        "Selected photo could not be loaded"
    }
}

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let maxSelectionCount: Int
    let completion: (PhotoImportSummary) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = maxSelectionCount
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let completion: (PhotoImportSummary) -> Void
        private var didFinish = false

        init(completion: @escaping (PhotoImportSummary) -> Void) {
            self.completion = completion
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !didFinish else { return }
            didFinish = true
            picker.dismiss(animated: true)

            guard !results.isEmpty else {
                completion(.empty)
                return
            }

            Task {
                let summary = await Self.importPhotos(from: results)
                await MainActor.run {
                    completion(summary)
                }
            }
        }

        private static func importPhotos(from results: [PHPickerResult]) async -> PhotoImportSummary {
            var summary = PhotoImportSummary()
            for result in results {
                do {
                    let photo = try await loadImageData(from: result.itemProvider)
                    guard Int64(photo.data.count) <= HarnessAPI.attachmentMaxBytes else {
                        summary.oversizedCount += 1
                        continue
                    }

                    let url = temporaryPhotoURL(contentType: photo.contentType)
                    try photo.data.write(to: url, options: .atomic)
                    summary.urls.append(url)
                } catch {
                    summary.failedCount += 1
                }
            }
            return summary
        }

        private static func loadImageData(from provider: NSItemProvider) async throws -> LoadedPhoto {
            guard let contentType = provider.registeredTypeIdentifiers
                .compactMap(UTType.init)
                .first(where: { $0.conforms(to: .image) }) else {
                throw PhotoImportError.unreadablePhoto
            }

            return try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: contentType.identifier) { data, error in
                    if let data {
                        continuation.resume(returning: LoadedPhoto(data: data, contentType: contentType))
                    } else {
                        continuation.resume(throwing: error ?? PhotoImportError.unreadablePhoto)
                    }
                }
            }
        }

        private static func temporaryPhotoURL(contentType: UTType) -> URL {
            let fileExtension = contentType.preferredFilenameExtension ?? "jpg"
            let filename = "photo-\(UUID().uuidString).\(fileExtension)"
            return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        }
    }

    private struct LoadedPhoto {
        let data: Data
        let contentType: UTType
    }
}
