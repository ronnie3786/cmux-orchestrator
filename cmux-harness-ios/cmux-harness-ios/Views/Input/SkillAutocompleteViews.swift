import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SkillAutocompleteContext: Equatable {
    let range: Range<String.Index>
    let query: String
    let invocationPrefix: String
    let signature: String

    init?(draft: String, selection: TextSelection?) {
        guard !draft.isEmpty else { return nil }
        let cursor = draft.insertionIndex(from: selection)
        guard cursor > draft.startIndex else { return nil }

        let prefix = draft[..<cursor]
        let tokenStart = prefix.lastIndex(where: { $0.isWhitespace }).map { draft.index(after: $0) } ?? draft.startIndex
        guard tokenStart < cursor else { return nil }
        let trigger = draft[tokenStart]
        guard trigger == "/" || trigger == "$" else { return nil }

        let token = draft[tokenStart..<cursor]
        guard !token.contains(where: { $0.isWhitespace }) else { return nil }

        range = tokenStart..<cursor
        query = String(token.dropFirst())
        invocationPrefix = String(trigger)
        let startOffset = draft.distance(from: draft.startIndex, to: tokenStart)
        signature = "\(startOffset):\(String(token))"
    }
}

struct SkillAutocompletePanel: View {
    let suggestions: [ProjectSkill]
    let invocationPrefix: String
    let cancelAction: () -> Void
    let selectAction: (ProjectSkill) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Skills")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.64))
                Spacer()
                Button {
                    HarnessHaptics.inputCTA()
                    cancelAction()
                } label: {
                    Text("Cancel")
                }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }

            ForEach(suggestions) { skill in
                Button {
                    HarnessHaptics.inputCTA()
                    selectAction(skill)
                } label: {
                    HStack(spacing: 10) {
                        Text("\(invocationPrefix)\(skill.name)")
                            .font(.subheadline.monospaced().weight(.semibold))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text(skill.scope == "user" ? "User" : "Project")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
        }
    }
}

extension String {
    func insertionIndex(from selection: TextSelection?) -> String.Index {
        guard let selection else { return endIndex }

        let proposedIndex: String.Index?
        switch selection.indices {
        case let .selection(range):
            proposedIndex = range.upperBound
        case let .multiSelection(ranges):
            proposedIndex = ranges.ranges.last?.upperBound
        @unknown default:
            proposedIndex = nil
        }

        guard let proposedIndex,
              proposedIndex == endIndex || indices.contains(proposedIndex) else {
            return endIndex
        }
        return proposedIndex
    }
}
