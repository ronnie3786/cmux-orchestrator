import SwiftUI

/// The floating `$`-skills picker that hangs above the composer.
///
/// Mac-only. It is a HUD, not a panel: it never takes focus, never blocks the
/// draft, and disappears the moment it stops being useful. All of its state
/// lives in `ComposerSkillsPalette`; this view only draws rows and reports
/// clicks and hovers back.
struct ComposerSkillsHUD: View {
    let matches: [ProjectSkill]
    /// How many skills the workspace has in total — the denominator in the footer count.
    let totalCount: Int
    let highlightedIndex: Int
    let query: String
    let visibleRowCount: Int
    let select: (Int) -> Void
    let highlight: (Int) -> Void

    /// Two lines of monospaced text plus breathing room.
    private static let rowHeight: CGFloat = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(HerdrTheme.surface)
                .frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, skill in
                            row(skill, at: index)
                                .id(index)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: Self.rowHeight * CGFloat(max(visibleRowCount, 1)))
                .onChange(of: highlightedIndex) { _, index in
                    proxy.scrollTo(index, anchor: .center)
                }
            }

            Rectangle()
                .fill(HerdrTheme.surface)
                .frame(height: 1)

            footer
        }
        .frame(maxWidth: 460, alignment: .leading)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
        .shadow(color: HerdrTheme.ink.opacity(0.55), radius: 14, y: 6)
        // The composer keeps the caret; a HUD that stole focus would break the
        // very typing it is trying to accelerate.
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace skills")
        .accessibilityIdentifier("skills-hud")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .herdrFont(.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.mauve)

            Text("$\(query)")
                .herdrFont(.caption, monospaced: true, weight: .bold)
                .foregroundStyle(HerdrTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text("↑↓ move")
                .herdrFont(.caption2, monospaced: true)
                .foregroundStyle(HerdrTheme.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(HerdrTheme.elevated)
        .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(countSummary)
            Spacer(minLength: 8)
            Text("↩ insert · esc")
        }
        .herdrFont(.caption2, monospaced: true)
        .foregroundStyle(HerdrTheme.muted)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(HerdrTheme.elevated)
        .accessibilityHidden(true)
    }

    /// "12 of 47 skills" while filtering, plain "47 skills" when the query is
    /// empty — the denominator never shrinks below what is on screen.
    private var countSummary: String {
        let total = max(totalCount, matches.count)
        let noun = total == 1 ? "skill" : "skills"
        return query.isEmpty ? "\(total) \(noun)" : "\(matches.count) of \(total) \(noun)"
    }

    private func row(_ skill: ProjectSkill, at index: Int) -> some View {
        Button {
            select(index)
        } label: {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(index == highlightedIndex ? HerdrTheme.accent : .clear)
                    .frame(width: 2)

                Image(systemName: skill.scope == "user" ? "person.crop.circle" : "shippingbox")
                    .herdrFont(.caption)
                    .foregroundStyle(skill.scope == "user" ? HerdrTheme.signal : HerdrTheme.mauve)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .herdrFont(.subheadline, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(1)

                    Text(skill.skillFilePath)
                        .herdrFont(.caption2, monospaced: true)
                        .foregroundStyle(HerdrTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)
            }
            .padding(.trailing, 12)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(index == highlightedIndex ? HerdrTheme.accent.opacity(0.16) : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering { highlight(index) }
        }
        .help("Insert $\(skill.name)")
        .accessibilityLabel("Insert \(skill.name) skill")
        .accessibilityIdentifier("skills-hud-row-\(skill.name)")
    }
}
