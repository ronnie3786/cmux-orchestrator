import Foundation

/// One tool call in a headless run, flattened for display.
///
/// A headless step carries only a tool *name* and two opaque preview strings —
/// never the structured `PiToolInvocation` the live chat gets — which is why
/// this leans on `PiToolPresentation.details(forToolName:)` rather than the
/// `init(tool:)` the chat uses.
struct HeadlessAgentStepRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let isFailure: Bool
    let isRunning: Bool

    static func rows(from steps: [HeadlessAgentStep]) -> [HeadlessAgentStepRow] {
        steps.enumerated().map { index, step in
            let toolName = step.toolName.flatMap { $0.isEmpty ? nil : $0 } ?? "Tool"
            let presentation = PiToolPresentation.details(forToolName: toolName)
            // Not every harness fills `toolCallId`, and ForEach needs a stable
            // key that survives a poll appending later steps. The index is
            // stable here because the server only ever appends.
            let identifier = step.toolCallId.flatMap { $0.isEmpty ? nil : $0 } ?? "agent-step-\(index)"
            return HeadlessAgentStepRow(
                id: identifier,
                title: presentation.title,
                detail: detail(for: step, isCommand: presentation.title == "Command"),
                symbol: presentation.symbol,
                isFailure: step.isError == true,
                isRunning: step.finishedAt == nil
            )
        }
    }

    private static func detail(for step: HeadlessAgentStep, isCommand: Bool) -> String {
        let preview: String?
        if isCommand {
            // A shell step's args arrive as JSON. Showing the raw object is
            // noise; the command line inside it is the whole point.
            preview = commandPreview(from: step.argsPreview) ?? step.argsPreview ?? step.resultPreview
        } else {
            preview = step.argsPreview ?? step.resultPreview
        }
        return singleLinePreview(preview ?? "")
    }

    private static func commandPreview(from preview: String?) -> String? {
        guard let preview,
              let data = preview.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return ["command", "cmd", "script"].lazy.compactMap { object[$0] as? String }.first
    }

    private static func singleLinePreview(_ preview: String) -> String {
        let singleLine = preview.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let limit = 120
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit - 1)) + "…"
    }
}
