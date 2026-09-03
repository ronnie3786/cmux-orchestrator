import SwiftUI

/// The visual vocabulary for result artifacts is intentionally independent of
/// the wire model. Adding a new file family only changes this classifier and
/// its presentation, while the HUD rail and opening pipeline stay generic.
enum HerdrHudResultArtifactCategory: String, CaseIterable, Sendable {
    case link
    case webPage
    case pdf
    case document
    case spreadsheet
    case presentation
    case image
    case video
    case audio
    case sourceCode
    case archive
    case generic

    init(artifact: AgentResultArtifact) {
        if artifact.kind == .link {
            self = .link
            return
        }

        let mimeType = artifact.contentType?.lowercased() ?? ""
        let fileExtension = (artifact.filename ?? artifact.displayTitle)
            .split(separator: ".")
            .last
            .map { String($0).lowercased() } ?? ""

        if mimeType == "application/pdf" || fileExtension == "pdf" {
            self = .pdf
        } else if mimeType == "text/html" || ["html", "htm"].contains(fileExtension) {
            self = .webPage
        } else if mimeType.hasPrefix("video/") || Self.videoExtensions.contains(fileExtension) {
            self = .video
        } else if mimeType.hasPrefix("image/") || Self.imageExtensions.contains(fileExtension) {
            self = .image
        } else if mimeType.hasPrefix("audio/") || Self.audioExtensions.contains(fileExtension) {
            self = .audio
        } else if Self.spreadsheetExtensions.contains(fileExtension) {
            self = .spreadsheet
        } else if Self.presentationExtensions.contains(fileExtension) {
            self = .presentation
        } else if Self.archiveExtensions.contains(fileExtension) {
            self = .archive
        } else if Self.sourceCodeExtensions.contains(fileExtension) || mimeType.hasPrefix("text/x-") {
            self = .sourceCode
        } else if Self.documentExtensions.contains(fileExtension)
                    || mimeType.hasPrefix("text/")
                    || mimeType.contains("wordprocessingml") {
            self = .document
        } else {
            self = .generic
        }
    }

    var symbol: String {
        switch self {
        case .link: "link"
        case .webPage: "globe.americas.fill"
        case .pdf: "doc.richtext.fill"
        case .document: "doc.text.fill"
        case .spreadsheet: "tablecells.fill"
        case .presentation: "rectangle.3.group.fill"
        case .image: "photo.fill"
        case .video: "play.rectangle.fill"
        case .audio: "waveform"
        case .sourceCode: "chevron.left.forwardslash.chevron.right"
        case .archive: "archivebox.fill"
        case .generic: "paperclip"
        }
    }

    var compactLabel: String {
        switch self {
        case .link: "LINK"
        case .webPage: "WEB"
        case .pdf: "PDF"
        case .document: "DOCUMENT"
        case .spreadsheet: "SHEET"
        case .presentation: "DECK"
        case .image: "IMAGE"
        case .video: "VIDEO"
        case .audio: "AUDIO"
        case .sourceCode: "CODE"
        case .archive: "ARCHIVE"
        case .generic: "FILE"
        }
    }

    /// A shoulder-surfing-safe label used whenever HUD session titles are
    /// redacted. It preserves the result's affordance without leaking its
    /// filename, URL host, or agent-provided title.
    var privacyLabel: String {
        switch self {
        case .link: "Link result"
        case .webPage: "Web result"
        case .pdf: "PDF result"
        case .document: "Document result"
        case .spreadsheet: "Spreadsheet result"
        case .presentation: "Presentation result"
        case .image: "Image result"
        case .video: "Video result"
        case .audio: "Audio result"
        case .sourceCode: "Code result"
        case .archive: "Archive result"
        case .generic: "File result"
        }
    }

    var tint: Color {
        switch self {
        case .link, .webPage, .spreadsheet, .sourceCode:
            HerdrTheme.accent
        case .pdf, .presentation, .video, .audio:
            HerdrTheme.mauve
        case .image:
            HerdrTheme.code
        case .document, .archive, .generic:
            HerdrTheme.mist
        }
    }

    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm",
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "svg",
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aiff", "aac", "flac", "ogg",
    ]
    private static let spreadsheetExtensions: Set<String> = [
        "xlsx", "xls", "csv", "numbers", "ods",
    ]
    private static let presentationExtensions: Set<String> = [
        "ppt", "pptx", "key", "odp",
    ]
    private static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar",
    ]
    private static let sourceCodeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "rs", "go", "py", "rb", "js", "jsx",
        "ts", "tsx", "java", "kt", "sh", "zsh", "css", "json", "yaml", "yml", "toml", "xml",
    ]
    private static let documentExtensions: Set<String> = [
        "txt", "md", "rtf", "doc", "docx", "pages", "odt",
    ]
}
