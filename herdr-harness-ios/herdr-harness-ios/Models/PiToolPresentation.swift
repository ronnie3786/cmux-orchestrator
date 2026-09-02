import SwiftUI

struct PiToolPresentation: Equatable, Sendable {
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color

    init(tool: PiToolInvocation) {
        let details = Self.details(forToolName: tool.name)
        let argument = tool.arguments
        title = details.title
        subtitle = details.argumentKeys.flatMap { Self.firstString(in: argument, keys: $0) }
        symbol = details.symbol
        tint = details.tint
    }

    static func details(forToolName name: String) -> (
        title: String,
        symbol: String,
        tint: Color,
        argumentKeys: [String]?
    ) {
        let normalized = name.lowercased().replacing("-", with: "_")
        if Self.matches(normalized, any: ["bash", "shell", "exec", "command", "run"]) {
            return ("Command", "terminal", HerdrTheme.signal, ["command", "cmd", "script"])
        } else if Self.matches(normalized, any: ["read", "open_file"]) {
            return ("Read", "doc.text", HerdrTheme.accent, ["path", "file", "filename"])
        } else if Self.matches(normalized, any: ["write", "create_file"]) {
            return ("Write", "doc.badge.plus", HerdrTheme.mauve, ["path", "file", "filename"])
        } else if Self.matches(normalized, any: ["edit", "patch", "apply_patch"]) {
            return ("Edit", "pencil.and.outline", HerdrTheme.mauve, ["path", "file", "filename"])
        } else if Self.matches(normalized, any: ["grep", "search", "find", "rg"]) {
            return ("Search", "magnifyingglass", HerdrTheme.working, ["query", "pattern", "path"])
        } else if Self.matches(normalized, any: ["web", "browser", "fetch", "http"]) {
            return ("Web", "globe", HerdrTheme.accent, ["url", "query"])
        } else {
            return (Self.humanize(name), "wrench.and.screwdriver", HerdrTheme.mist, nil)
        }
    }

    private static func matches(_ name: String, any fragments: [String]) -> Bool {
        fragments.contains { name == $0 || name.contains("_\($0)") || name.contains("\($0)_") }
    }

    private static func firstString(in value: PiJSONValue?, keys: [String]) -> String? {
        guard let value else { return nil }
        for key in keys {
            if let string = value[key]?.stringValue, !string.isEmpty {
                return string.split(separator: "\n", maxSplits: 1).first.map(String.init)
            }
        }
        return nil
    }

    private static func humanize(_ name: String) -> String {
        name.replacing("_", with: " ")
            .replacing("-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
