import SwiftUI

struct PiToolPresentation: Equatable, Sendable {
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color

    init(tool: PiToolInvocation) {
        let normalized = tool.name.lowercased().replacing("-", with: "_")
        let argument = tool.arguments
        if Self.matches(normalized, any: ["bash", "shell", "exec", "command", "run"]) {
            title = "Command"
            subtitle = Self.firstString(in: argument, keys: ["command", "cmd", "script"])
            symbol = "terminal"
            tint = HerdrTheme.signal
        } else if Self.matches(normalized, any: ["read", "open_file"]) {
            title = "Read"
            subtitle = Self.firstString(in: argument, keys: ["path", "file", "filename"])
            symbol = "doc.text"
            tint = HerdrTheme.accent
        } else if Self.matches(normalized, any: ["write", "create_file"]) {
            title = "Write"
            subtitle = Self.firstString(in: argument, keys: ["path", "file", "filename"])
            symbol = "doc.badge.plus"
            tint = HerdrTheme.mauve
        } else if Self.matches(normalized, any: ["edit", "patch", "apply_patch"]) {
            title = "Edit"
            subtitle = Self.firstString(in: argument, keys: ["path", "file", "filename"])
            symbol = "pencil.and.outline"
            tint = HerdrTheme.mauve
        } else if Self.matches(normalized, any: ["grep", "search", "find", "rg"]) {
            title = "Search"
            subtitle = Self.firstString(in: argument, keys: ["query", "pattern", "path"])
            symbol = "magnifyingglass"
            tint = HerdrTheme.working
        } else if Self.matches(normalized, any: ["web", "browser", "fetch", "http"]) {
            title = "Web"
            subtitle = Self.firstString(in: argument, keys: ["url", "query"])
            symbol = "globe"
            tint = HerdrTheme.accent
        } else {
            title = Self.humanize(tool.name)
            subtitle = nil
            symbol = "wrench.and.screwdriver"
            tint = HerdrTheme.mist
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
