import Foundation

/// Source of truth for which files the HUD composer will let the user attach.
///
/// Mirrors `herdr_harness/agent_runs.py: ATTACHMENT_EXTENSIONS` exactly — if you
/// change one, change the other. The client-side check exists purely so an
/// unsupported file fails instantly in the UI instead of after a 20 MB upload
/// round trip to the harness, which performs the authoritative check.
enum HerdrAttachmentTypes {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "svg",
    ]
    static let allowedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "svg",
        "pdf", "txt", "md", "markdown", "rtf", "csv", "tsv", "log",
        "json", "yaml", "yml", "toml", "xml", "plist", "ini", "conf",
        "swift", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "rb", "go", "rs", "java",
        "kt", "kts", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "php", "sh", "bash",
        "zsh", "sql", "gradle", "patch", "diff",
    ]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func isAllowed(_ url: URL) -> Bool {
        allowedExtensions.contains(url.pathExtension.lowercased())
    }
}
