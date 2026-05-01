import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DiffSheetView: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let diffSheet: DiffSheet
    @State private var selectedLine: ParsedDiffLine?

    var body: some View {
        NavigationStack {
            Group {
                if diffSheet.isLoading {
                    ProgressView()
                } else if let error = diffSheet.error {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                } else {
                    GeometryReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                DiffCommentInstructionNote()
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 8)

                                ForEach(parseUnifiedDiffLines(diffSheet.diff)) { line in
                                    DiffLineRow(line: line) {
                                        selectedLine = line
                                    }
                                }
                            }
                            .frame(width: proxy.size.width, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                        .background(Color(.systemBackground))
                    }
                }
            }
            .navigationTitle(diffSheet.file)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.send(.closeDiff)
                    }
                }
            }
        }
        .sheet(item: $selectedLine) { line in
            DiffLineCommentSheet(
                file: diffSheet.file,
                line: line,
                submitAction: { reviewComment in
                    selectedLine = nil
                    store.send(.appendDiffLineReviewComment(reviewComment))
                }
            )
            .presentationDetents([.height(460), .medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color(.systemBackground))
        }
    }
}

struct DiffCommentInstructionNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)

            Text("Tap a line of code to add a comment or instruction to send.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
        }
    }
}

enum ParsedDiffLineKind: Equatable {
    case metadata
    case hunk
    case context
    case addition
    case deletion
}

struct ParsedDiffLine: Equatable, Identifiable {
    var id: Int
    var raw: String
    var kind: ParsedDiffLineKind
    var oldLineNumber: Int?
    var newLineNumber: Int?

    var isCommentable: Bool {
        switch kind {
        case .addition, .deletion, .context:
            return true
        case .metadata, .hunk:
            return false
        }
    }

    var marker: String {
        switch kind {
        case .addition:
            return "+"
        case .deletion:
            return "-"
        case .context:
            return " "
        case .hunk, .metadata:
            return ""
        }
    }

    var code: String {
        guard isCommentable, !raw.isEmpty else { return raw }
        return String(raw.dropFirst())
    }

    var displayText: String {
        isCommentable ? code : raw
    }

    var reviewLineNumber: Int? {
        switch kind {
        case .deletion:
            return oldLineNumber
        case .addition, .context:
            return newLineNumber ?? oldLineNumber
        case .metadata, .hunk:
            return nil
        }
    }

    var reviewSide: DiffLineCommentSide {
        switch kind {
        case .deletion:
            return .old
        case .addition:
            return .new
        case .context:
            return .context
        case .metadata, .hunk:
            return .context
        }
    }

    func reviewComment(file: String, comment: String) -> DiffLineReviewComment {
        DiffLineReviewComment(
            file: file,
            lineNumber: reviewLineNumber,
            side: reviewSide,
            code: code,
            comment: comment
        )
    }
}

struct DiffLineRow: View {
    let line: ParsedDiffLine
    let commentAction: () -> Void

    var body: some View {
        Group {
            if line.isCommentable {
                Button(action: commentAction) {
                    rowContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldLineNumber.map(String.init) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(gutterColor)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 8)

            Text(line.newLineNumber.map(String.init) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(gutterColor)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 8)

            Text(line.marker)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(diffColor(for: line.raw))
                .frame(width: 18, alignment: .center)

            Text(line.displayText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(diffColor(for: line.raw))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 6)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: line.kind == .hunk ? 32 : 28, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    private var rowBackground: Color {
        if line.kind == .hunk {
            return Color.blue.opacity(0.10)
        }
        return diffBackground(for: line.raw)
    }

    private var gutterColor: Color {
        line.isCommentable ? .secondary : .secondary.opacity(0.5)
    }

    private var accessibilityLabel: String {
        let lineNumber = line.reviewLineNumber.map(String.init) ?? "unknown"
        return "Add review comment on line \(lineNumber)"
    }
}

struct DiffLineCommentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var comment = ""

    let file: String
    let line: ParsedDiffLine
    let submitAction: (DiffLineReviewComment) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                selectedLinePreview

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $comment)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 130)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 1)
                        }

                    if comment.isEmpty {
                        Text("Comment")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    submit()
                } label: {
                    Label("Insert Comment", systemImage: "text.bubble.fill")
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedComment.isEmpty)
            }
            .padding(18)
            .navigationTitle("Review Comment")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemBackground).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var selectedLinePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(file, systemImage: "doc.text")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Text(lineLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 0) {
                Text(line.marker.isEmpty ? " " : line.marker)
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(diffColor(for: line.raw))

                Text(" \(previewCode)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(diffBackground(for: line.raw).opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 1)
        }
    }

    private var lineLabel: String {
        guard let lineNumber = line.reviewLineNumber else { return line.reviewSide.promptLabel }
        return "\(lineNumber) \(line.reviewSide.promptLabel)"
    }

    private var previewCode: String {
        let code = line.code.trimmingCharacters(in: .whitespaces)
        return code.isEmpty ? "(blank line)" : code
    }

    private var trimmedComment: String {
        comment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedComment.isEmpty else { return }
        submitAction(line.reviewComment(file: file, comment: trimmedComment))
        dismiss()
    }
}

func parseUnifiedDiffLines(_ diff: String) -> [ParsedDiffLine] {
    var oldLineNumber: Int?
    var newLineNumber: Int?

    return diff.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
        .map { offset, rawSubstring in
            let raw = String(rawSubstring)

            if let hunkStart = parseHunkStart(from: raw) {
                oldLineNumber = hunkStart.old
                newLineNumber = hunkStart.new
                return ParsedDiffLine(
                    id: offset,
                    raw: raw,
                    kind: .hunk,
                    oldLineNumber: nil,
                    newLineNumber: nil
                )
            }

            if raw.hasPrefix("+"), !raw.hasPrefix("+++") {
                defer { newLineNumber = newLineNumber.map { $0 + 1 } }
                return ParsedDiffLine(
                    id: offset,
                    raw: raw,
                    kind: .addition,
                    oldLineNumber: nil,
                    newLineNumber: newLineNumber
                )
            }

            if raw.hasPrefix("-"), !raw.hasPrefix("---") {
                defer { oldLineNumber = oldLineNumber.map { $0 + 1 } }
                return ParsedDiffLine(
                    id: offset,
                    raw: raw,
                    kind: .deletion,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: nil
                )
            }

            if raw.hasPrefix(" ") {
                defer {
                    oldLineNumber = oldLineNumber.map { $0 + 1 }
                    newLineNumber = newLineNumber.map { $0 + 1 }
                }
                return ParsedDiffLine(
                    id: offset,
                    raw: raw,
                    kind: .context,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: newLineNumber
                )
            }

            return ParsedDiffLine(
                id: offset,
                raw: raw,
                kind: .metadata,
                oldLineNumber: nil,
                newLineNumber: nil
            )
        }
}

func parseHunkStart(from line: String) -> (old: Int, new: Int)? {
    guard line.hasPrefix("@@") else { return nil }
    let parts = line.split(separator: " ")
    guard let oldPart = parts.first(where: { $0.hasPrefix("-") }),
          let newPart = parts.first(where: { $0.hasPrefix("+") }),
          let oldStart = parseHunkLineStart(oldPart),
          let newStart = parseHunkLineStart(newPart) else {
        return nil
    }
    return (oldStart, newStart)
}

func parseHunkLineStart(_ part: Substring) -> Int? {
    let value = part.dropFirst()
    let lineStart = value.split(separator: ",", maxSplits: 1).first ?? value
    return Int(lineStart)
}
