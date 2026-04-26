import Foundation
import SwiftUI

enum TerminalTextStyler {
    static func attributedString(for raw: String, colorScheme: ColorScheme) -> AttributedString {
        let runs = TerminalSemanticHighlighter.highlight(ANSIParser.parse(raw))
        var result = AttributedString()

        for run in runs where !run.text.isEmpty {
            var attributed = AttributedString(run.text)
            attributed.font = font(for: run.style)
            attributed.foregroundColor = TerminalPalette.foreground(for: run.style, colorScheme: colorScheme)
            if let background = TerminalPalette.background(for: run.style.background, colorScheme: colorScheme) {
                attributed.backgroundColor = background
            }
            if run.style.underline {
                attributed.underlineStyle = .single
            }
            result += attributed
        }

        return result
    }

    static func plainText(for raw: String) -> String {
        ANSIParser.parse(raw).map(\.text).joined()
    }

    static func terminalBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? TerminalPalette.darkBackground : TerminalPalette.lightBackground
    }

    private static func font(for style: TerminalTextStyle) -> Font {
        var font = Font.system(.caption, design: .monospaced)
        if style.bold {
            font = font.weight(.semibold)
        }
        if style.italic {
            font = font.italic()
        }
        return font
    }
}

private struct TerminalRun: Equatable {
    var text: String
    var style: TerminalTextStyle
}

private struct TerminalTextStyle: Equatable {
    var foreground: TerminalColor?
    var background: TerminalColor?
    var bold = false
    var dim = false
    var italic = false
    var underline = false

    mutating func apply(_ patch: TerminalStylePatch) {
        if let foreground = patch.foreground,
           patch.overridesForeground || self.foreground == nil {
            self.foreground = foreground
        }
        if let background = patch.background,
           patch.overridesBackground || self.background == nil {
            self.background = background
        }
        if patch.bold {
            bold = true
        }
        if patch.dim {
            dim = true
        }
        if patch.italic {
            italic = true
        }
        if patch.underline {
            underline = true
        }
    }

    mutating func applySGR(_ codes: [Int]) {
        guard !codes.isEmpty else {
            self = TerminalTextStyle()
            return
        }

        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0:
                self = TerminalTextStyle()
            case 1:
                bold = true
            case 2:
                dim = true
            case 3:
                italic = true
            case 4:
                underline = true
            case 22:
                bold = false
                dim = false
            case 23:
                italic = false
            case 24:
                underline = false
            case 30...37, 90...97:
                foreground = .named(TerminalNamedColor.foreground(code))
            case 39:
                foreground = nil
            case 40...47, 100...107:
                background = .named(TerminalNamedColor.background(code))
            case 49:
                background = nil
            case 38, 48:
                let isForeground = code == 38
                if let color = ANSIParser.extendedColor(from: codes, startingAt: index + 1) {
                    if isForeground {
                        foreground = color.value
                    } else {
                        background = color.value
                    }
                    index = color.nextIndex - 1
                }
            default:
                break
            }
            index += 1
        }
    }
}

private struct TerminalStylePatch {
    var foreground: TerminalColor?
    var background: TerminalColor?
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var overridesForeground = false
    var overridesBackground = false
}

private enum TerminalColor: Equatable {
    case named(TerminalNamedColor)
    case rgb(red: Int, green: Int, blue: Int)
}

private enum TerminalNamedColor: Equatable {
    case black
    case red
    case green
    case yellow
    case blue
    case magenta
    case cyan
    case white
    case brightBlack
    case brightRed
    case brightGreen
    case brightYellow
    case brightBlue
    case brightMagenta
    case brightCyan
    case brightWhite
    case muted
    case accent

    static func foreground(_ code: Int) -> TerminalNamedColor {
        switch code {
        case 30: .black
        case 31: .red
        case 32: .green
        case 33: .yellow
        case 34: .blue
        case 35: .magenta
        case 36: .cyan
        case 37: .white
        case 90: .brightBlack
        case 91: .brightRed
        case 92: .brightGreen
        case 93: .brightYellow
        case 94: .brightBlue
        case 95: .brightMagenta
        case 96: .brightCyan
        default: .brightWhite
        }
    }

    static func background(_ code: Int) -> TerminalNamedColor {
        foreground(code - 10)
    }
}

private enum TerminalPalette {
    static let darkBackground = Color(red: 0.02, green: 0.03, blue: 0.04)
    static let lightBackground = Color(red: 0.96, green: 0.97, blue: 0.99)

    static func foreground(for style: TerminalTextStyle, colorScheme: ColorScheme) -> Color {
        let resolvedColor = style.foreground.map { color(for: $0, colorScheme: colorScheme) }
            ?? (colorScheme == .dark ? hex(0xD8DDE8) : hex(0x1E293B))
        return style.dim ? resolvedColor.opacity(0.6) : resolvedColor
    }

    static func background(for color: TerminalColor?, colorScheme: ColorScheme) -> Color? {
        guard let color else { return nil }
        switch color {
        case let .rgb(red, green, blue):
            return Color(
                red: Double(clamped(red)) / 255.0,
                green: Double(clamped(green)) / 255.0,
                blue: Double(clamped(blue)) / 255.0
            ).opacity(colorScheme == .dark ? 0.35 : 0.18)
        case let .named(named):
            return backgroundColor(for: named, colorScheme: colorScheme)
        }
    }

    private static func color(for color: TerminalColor, colorScheme: ColorScheme) -> Color {
        switch color {
        case let .rgb(red, green, blue):
            return Color(
                red: Double(clamped(red)) / 255.0,
                green: Double(clamped(green)) / 255.0,
                blue: Double(clamped(blue)) / 255.0
            )
        case let .named(named):
            return foregroundColor(for: named, colorScheme: colorScheme)
        }
    }

    private static func foregroundColor(for named: TerminalNamedColor, colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            switch named {
            case .black: return hex(0x546178)
            case .red: return hex(0xF87171)
            case .green: return hex(0x34D399)
            case .yellow: return hex(0xFBBF24)
            case .blue: return hex(0x60A5FA)
            case .magenta: return hex(0xC084FC)
            case .cyan: return hex(0x22D3EE)
            case .white: return hex(0xE2E8F0)
            case .brightBlack, .muted: return hex(0x7A8BA4)
            case .brightRed: return hex(0xFCA5A5)
            case .brightGreen: return hex(0x6EE7B7)
            case .brightYellow: return hex(0xFDE68A)
            case .brightBlue, .accent: return hex(0x93C5FD)
            case .brightMagenta: return hex(0xD8B4FE)
            case .brightCyan: return hex(0x67E8F9)
            case .brightWhite: return hex(0xF8FAFC)
            }
        }

        switch named {
        case .black: return hex(0x334155)
        case .red, .brightRed: return hex(0xDC2626)
        case .green, .brightGreen: return hex(0x059669)
        case .yellow, .brightYellow: return hex(0xB45309)
        case .blue, .brightBlue, .accent: return hex(0x2563EB)
        case .magenta, .brightMagenta: return hex(0x9333EA)
        case .cyan, .brightCyan: return hex(0x0891B2)
        case .white, .brightWhite: return hex(0x475569)
        case .brightBlack, .muted: return hex(0x64748B)
        }
    }

    private static func backgroundColor(for named: TerminalNamedColor, colorScheme: ColorScheme) -> Color {
        let opacity = colorScheme == .dark ? 0.25 : 0.14
        switch named {
        case .black:
            return colorScheme == .dark ? hex(0x1E293B) : hex(0xCBD5E1)
        case .brightBlack:
            return colorScheme == .dark ? hex(0x334155) : hex(0xE2E8F0)
        case .red, .brightRed:
            return foregroundColor(for: .red, colorScheme: colorScheme).opacity(opacity)
        case .green, .brightGreen:
            return foregroundColor(for: .green, colorScheme: colorScheme).opacity(opacity)
        case .yellow, .brightYellow:
            return foregroundColor(for: .yellow, colorScheme: colorScheme).opacity(opacity)
        case .blue, .brightBlue, .accent:
            return foregroundColor(for: .blue, colorScheme: colorScheme).opacity(opacity)
        case .magenta, .brightMagenta:
            return foregroundColor(for: .magenta, colorScheme: colorScheme).opacity(opacity)
        case .cyan, .brightCyan:
            return foregroundColor(for: .cyan, colorScheme: colorScheme).opacity(opacity)
        case .white, .brightWhite, .muted:
            return foregroundColor(for: .white, colorScheme: colorScheme).opacity(opacity)
        }
    }

    private static func hex(_ value: Int) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    private static func clamped(_ value: Int) -> Int {
        min(255, max(0, value))
    }
}

private enum ANSIParser {
    static func parse(_ raw: String) -> [TerminalRun] {
        var runs: [TerminalRun] = []
        var style = TerminalTextStyle()
        var buffer = ""
        var index = raw.startIndex

        func flush() {
            guard !buffer.isEmpty else { return }
            runs.append(TerminalRun(text: buffer, style: style))
            buffer = ""
        }

        while index < raw.endIndex {
            if raw[index] == "\u{001B}" {
                if let sequence = controlSequence(in: raw, from: index) {
                    flush()
                    if sequence.final == "m" {
                        style.applySGR(sgrCodes(from: sequence.parameters))
                    }
                    index = sequence.end
                    continue
                }

                if let end = operatingSystemCommandEnd(in: raw, from: index) {
                    flush()
                    index = end
                    continue
                }

                index = raw.index(after: index)
                continue
            }

            buffer.append(raw[index])
            index = raw.index(after: index)
        }

        flush()
        return coalesce(runs)
    }

    static func extendedColor(from codes: [Int], startingAt index: Int) -> (value: TerminalColor, nextIndex: Int)? {
        guard index < codes.count else { return nil }
        switch codes[index] {
        case 5:
            guard index + 1 < codes.count,
                  let rgb = rgbForANSI256(codes[index + 1]) else {
                return nil
            }
            return (.rgb(red: rgb.red, green: rgb.green, blue: rgb.blue), index + 2)
        case 2:
            guard index + 3 < codes.count else { return nil }
            return (.rgb(red: codes[index + 1], green: codes[index + 2], blue: codes[index + 3]), index + 4)
        default:
            return nil
        }
    }

    private static func sgrCodes(from parameters: String) -> [Int] {
        if parameters.isEmpty { return [0] }
        return parameters
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
    }

    private static func controlSequence(in raw: String, from escapeIndex: String.Index) -> (parameters: String, final: Character, end: String.Index)? {
        let afterEscape = raw.index(after: escapeIndex)
        guard afterEscape < raw.endIndex, raw[afterEscape] == "[" else { return nil }

        var scan = raw.index(after: afterEscape)
        let parameterStart = scan
        while scan < raw.endIndex {
            guard let scalar = raw[scan].unicodeScalars.first else { return nil }
            if scalar.value >= 0x40, scalar.value <= 0x7E {
                let parameters = String(raw[parameterStart..<scan])
                return (parameters, raw[scan], raw.index(after: scan))
            }
            scan = raw.index(after: scan)
        }
        return nil
    }

    private static func operatingSystemCommandEnd(in raw: String, from escapeIndex: String.Index) -> String.Index? {
        let afterEscape = raw.index(after: escapeIndex)
        guard afterEscape < raw.endIndex, raw[afterEscape] == "]" else { return nil }

        var scan = raw.index(after: afterEscape)
        while scan < raw.endIndex {
            if raw[scan] == "\u{0007}" {
                return raw.index(after: scan)
            }
            if raw[scan] == "\u{001B}" {
                let next = raw.index(after: scan)
                if next < raw.endIndex, raw[next] == "\\" {
                    return raw.index(after: next)
                }
            }
            scan = raw.index(after: scan)
        }
        return raw.endIndex
    }

    private static func rgbForANSI256(_ value: Int) -> (red: Int, green: Int, blue: Int)? {
        guard value >= 0, value <= 255 else { return nil }

        let baseColors = [
            (0, 0, 0), (128, 0, 0), (0, 128, 0), (128, 128, 0),
            (0, 0, 128), (128, 0, 128), (0, 128, 128), (192, 192, 192),
            (128, 128, 128), (255, 0, 0), (0, 255, 0), (255, 255, 0),
            (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
        ]

        if value < baseColors.count {
            return baseColors[value]
        }

        if value >= 232 {
            let level = 8 + (value - 232) * 10
            return (level, level, level)
        }

        let cubeIndex = value - 16
        let red = cubeIndex / 36
        let green = (cubeIndex % 36) / 6
        let blue = cubeIndex % 6
        let levels = [0, 95, 135, 175, 215, 255]
        return (levels[red], levels[green], levels[blue])
    }

    private static func coalesce(_ runs: [TerminalRun]) -> [TerminalRun] {
        runs.reduce(into: []) { result, run in
            guard !run.text.isEmpty else { return }
            if let last = result.last, last.style == run.style {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
    }
}

private enum TerminalSemanticHighlighter {
    static func highlight(_ runs: [TerminalRun]) -> [TerminalRun] {
        patterns.reduce(runs) { currentRuns, pattern in
            currentRuns.flatMap { apply(pattern, to: $0) }
        }
    }

    private static let patterns: [TerminalTextPattern] = [
        TerminalTextPattern(
            #"(?m)^@@[^\n]*"#,
            patch: TerminalStylePatch(foreground: .named(.magenta), bold: true, overridesForeground: true)
        ),
        TerminalTextPattern(
            #"(?m)^\+[^\n]*"#,
            patch: TerminalStylePatch(foreground: .named(.green), overridesForeground: false)
        ),
        TerminalTextPattern(
            #"(?m)^-[^\n]*"#,
            patch: TerminalStylePatch(foreground: .named(.red), overridesForeground: false)
        ),
        TerminalTextPattern(
            #"(?m)^>\s*[^\n]*"#,
            patch: TerminalStylePatch(foreground: .named(.brightBlue), background: .named(.blue), bold: true)
        ),
        TerminalTextPattern(
            #"(?m)^\s*\x{23FA}\s*[^\n]*"#,
            patch: TerminalStylePatch(foreground: .named(.brightWhite), background: .named(.brightBlack))
        ),
        TerminalTextPattern(
            #"(?m)^\s*\x{23BF}\s*[^\n]*"#,
            patch: TerminalStylePatch(foreground: .named(.muted), dim: true)
        ),
        TerminalTextPattern(
            #"(?m)^\s*(?:\x{23FA}|\x{23BF}|>|\$|\x{276F}|\)|\x{2022}|-|\d+[.)])"#,
            patch: TerminalStylePatch(foreground: .named(.brightYellow), bold: true, overridesForeground: true)
        ),
        TerminalTextPattern(
            #"(?:\x{26A1}\s*)?(Read|Edit|Write|Update|Create|Delete|Bash|MultiEdit|Search|Glob|Grep|ListDir|Fetch|Browse|TodoRead|TodoWrite|WebFetch|MCP|WebSearch|Task|Call|Analyze|NotebookRead|NotebookEdit)(?=\()"#,
            patch: TerminalStylePatch(foreground: .named(.magenta), bold: true, overridesForeground: true)
        ),
        TerminalTextPattern(
            #"\b(?:file_path|path|pattern|command|what|description|prompt|url|query|old_string|new_string|replace_all):"#,
            patch: TerminalStylePatch(foreground: .named(.cyan), bold: true, overridesForeground: true)
        ),
        TerminalTextPattern(
            #""[^"\n]{1,180}""#,
            patch: TerminalStylePatch(foreground: .named(.brightGreen), overridesForeground: true)
        ),
        TerminalTextPattern(
            #"(?:\+\d+\s+-\d+|\d+\s+additions?(?:\(\+\))?|\d+\s+removals?(?:\(-\))?)"#,
            patch: TerminalStylePatch(foreground: .named(.brightYellow), bold: true, overridesForeground: true)
        ),
        TerminalTextPattern(
            #"\b(?:Updated|Created|Deleted|Wrote|Patched|Modified|Edited)\b(?=[^\n]*(?:with|\())"#,
            patch: TerminalStylePatch(foreground: .named(.green), bold: true, overridesForeground: true)
        ),
        TerminalTextPattern(
            #"(?m)^##\s+[^\n]*"#,
            patch: TerminalStylePatch(foreground: .named(.brightBlue), bold: true, overridesForeground: true)
        ),
        TerminalTextPattern(
            #"(?m)^\s*\d+[.)]\s+[^\n]*"#,
            patch: TerminalStylePatch(foreground: .named(.brightWhite))
        ),
        TerminalTextPattern(
            #"\b(?:pass|passed|succeeded|success|Built version|No ESLint warnings or errors|Ran \d+ tests?)\b"#,
            patch: TerminalStylePatch(foreground: .named(.green), bold: true, overridesForeground: true)
        ),
        TerminalTextPattern(
            #"(?m)^\s*(?:\x{2022}|-)\s*(?:Ran|Read|Edited|Updated|Created|Deleted|Added|Modified|Searched|Listed|Checked|Opened|Wrote|Patched|Built|Tested)\b[^\n]*"#,
            patch: TerminalStylePatch(foreground: .named(.cyan), bold: true)
        ),
        TerminalTextPattern(
            #"(?m)^\s*[\x{276F})]\s*"#,
            patch: TerminalStylePatch(foreground: .named(.green), bold: true)
        ),
        TerminalTextPattern(
            #"(?m)^\$\s"#,
            patch: TerminalStylePatch(foreground: .named(.green), bold: true)
        ),
        TerminalTextPattern(
            #"\b(?:Musing|Thinking|Processing|Running|Working)\.\.\."#,
            patch: TerminalStylePatch(foreground: .named(.green), italic: true, overridesForeground: true)
        ),
        TerminalTextPattern(
            #"(?:\([Yy](?:/[Nn]|es/no)\)|Allow\s+(?:Read|Write|Edit|Bash|Browser|MCP|Fetch|MultiEdit))"#,
            patch: TerminalStylePatch(foreground: .named(.yellow), bold: true, overridesForeground: true)
        ),
        TerminalTextPattern(
            #"\b(?:Model:\s*[^\n]+|Cost:\s*\$[^\n]+|Ctx:\s*[^\n]+)"#,
            patch: TerminalStylePatch(foreground: .named(.muted), dim: true, overridesForeground: true)
        ),
        TerminalTextPattern(
            #"(?:Build complete!|All \d+ tests passed|[\x{2713}\x{2714}][^\n]*|\bDone[.!]?)"#,
            patch: TerminalStylePatch(foreground: .named(.green), bold: true, overridesForeground: true)
        ),
        TerminalTextPattern(
            #"(?:error:|Error:|ERROR|failed|Failed|FAILED|warning:|Warning:|timed out|timeout)"#,
            patch: TerminalStylePatch(foreground: .named(.red), bold: true, overridesForeground: true)
        ),
        TerminalTextPattern(
            #"(?:(?:Sources|Tests|Packages|App|src|lib|test|spec|config|public|views|models|controllers)/[^\s<]+|[A-Za-z0-9_\-]+\.(?:swift|ts|tsx|js|jsx|py|rb|go|rs|json|yaml|yml|toml|css|html|md|sh|sql|xml|plist|h|m|c|cpp|java|kt))"#,
            patch: TerminalStylePatch(foreground: .named(.accent))
        ),
    ]

    private static func apply(_ pattern: TerminalTextPattern, to run: TerminalRun) -> [TerminalRun] {
        let text = run.text
        let matches = pattern.regex.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
        guard !matches.isEmpty else { return [run] }

        var result: [TerminalRun] = []
        var currentIndex = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text),
                  range.lowerBound >= currentIndex else {
                continue
            }

            if currentIndex < range.lowerBound {
                result.append(TerminalRun(text: String(text[currentIndex..<range.lowerBound]), style: run.style))
            }

            var highlightedStyle = run.style
            highlightedStyle.apply(pattern.patch)
            result.append(TerminalRun(text: String(text[range]), style: highlightedStyle))
            currentIndex = range.upperBound
        }

        if currentIndex < text.endIndex {
            result.append(TerminalRun(text: String(text[currentIndex..<text.endIndex]), style: run.style))
        }

        return result
    }
}

private struct TerminalTextPattern {
    var regex: NSRegularExpression
    var patch: TerminalStylePatch

    init(_ pattern: String, patch: TerminalStylePatch) {
        self.regex = try! NSRegularExpression(pattern: pattern)
        self.patch = patch
    }
}
