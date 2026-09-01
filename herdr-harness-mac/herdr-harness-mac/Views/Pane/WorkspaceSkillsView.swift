import SwiftUI

struct WorkspaceSkillsView: View {
    let workspace: HerdrWorkspace
    let loadSkills: () async throws -> SkillsResponse
    let selectToken: (String) -> Void

    @State private var response: SkillsResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                skillsHeader

                if isLoading, response == nil {
                    loadingCard
                } else if let errorMessage, response == nil {
                    errorCard(errorMessage)
                } else if let response {
                    skillsContent(response)
                } else {
                    emptyCard
                }
            }
            .padding(.horizontal, HerdrTheme.pagePadding)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .task(id: workspace.id) { await refresh() }
        .herdrHaptic(trigger: hapticPulse)
        .accessibilityIdentifier("workspace-skills")
    }

    private var skillsHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(HerdrTheme.mauve)

                Text("workspace skills")
                    .herdrFont(.headline, monospaced: true, weight: .bold)
                    .foregroundStyle(HerdrTheme.text)

                Spacer(minLength: 8)

                if let response {
                    Text("\(response.resolvedProjectSkills.count + response.resolvedUserSkills.count) found")
                        .herdrFont(.caption, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.signal)
                }

                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .herdrHitTarget(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HerdrTheme.accent)
                .disabled(isLoading)
                .symbolEffect(.rotate, options: .repeating, isActive: isLoading)
                .accessibilityLabel("Refresh skills")
            }

            Text(response?.rootPath?.nonEmpty ?? workspace.displayPath)
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func skillsContent(_ skills: SkillsResponse) -> some View {
        if let errorMessage {
            errorCard(errorMessage)
        }

        if skills.resolvedProjectSkills.isEmpty && skills.resolvedUserSkills.isEmpty {
            emptyCard
        }

        if !skills.resolvedProjectSkills.isEmpty {
            SkillScopeSection(
                title: "project skills",
                detail: skills.skillsDirectory,
                skills: skills.resolvedProjectSkills,
                select: insert
            )
        }

        if !skills.resolvedUserSkills.isEmpty {
            SkillScopeSection(
                title: "user skills",
                detail: skills.userSkillsDirectory,
                skills: skills.resolvedUserSkills,
                select: insert
            )
        }

        VStack(alignment: .leading, spacing: 8) {
            Label("Add to terminal", systemImage: "arrow.turn.down.left")
                .herdrFont(.caption, monospaced: true, weight: .bold)
                .foregroundStyle(HerdrTheme.accent)
            Text("Choose a skill, then insert it as a Claude command, Codex invocation, or file reference.")
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(HerdrTheme.accent)
            Text("Indexing project and user skills…")
                .herdrFont(.subheadline, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Skills unavailable", systemImage: "exclamationmark.triangle.fill")
                .herdrFont(.subheadline, monospaced: true, weight: .bold)
                .foregroundStyle(HerdrTheme.alert)
            Text(message)
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
            Button("Try again", systemImage: "arrow.clockwise") {
                Task { await refresh() }
            }
            .buttonStyle(.plain)
            .herdrFont(.subheadline, monospaced: true, weight: .bold)
            .foregroundStyle(HerdrTheme.accent)
            .frame(minHeight: 44)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.alert.opacity(0.7), lineWidth: 1)
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .herdrFont(.title2)
                .foregroundStyle(HerdrTheme.mist)
            Text("No skills found")
                .herdrFont(.subheadline, monospaced: true, weight: .bold)
                .foregroundStyle(HerdrTheme.text)
            Text("Add project skills under .claude/skills or user skills under your configured skills directory.")
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 140)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
    }

    private func insert(_ skill: ProjectSkill, as style: SkillInsertionStyle) {
        let token = style.token(for: skill)
        hapticPulse.fire(.selection)
        selectToken(token)
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            response = try await loadSkills()
            errorMessage = response?.error
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SkillScopeSection: View {
    let title: String
    let detail: String?
    let skills: [ProjectSkill]
    let select: (ProjectSkill, SkillInsertionStyle) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .bold()
                        .underline()
                    Spacer()
                    Text("\(skills.count)")
                }
                if let detail = detail?.nonEmpty {
                    Text(detail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .herdrFont(.caption, monospaced: true)
            .foregroundStyle(HerdrTheme.mist)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(HerdrTheme.elevated)

            ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                SkillMenuRow(skill: skill, select: select)
                if index < skills.count - 1 {
                    Rectangle()
                        .fill(HerdrTheme.surface)
                        .frame(height: 1)
                        .padding(.leading, 14)
                }
            }
        }
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
    }
}

private struct SkillMenuRow: View {
    let skill: ProjectSkill
    let select: (ProjectSkill, SkillInsertionStyle) -> Void

    var body: some View {
        Menu {
            ForEach(SkillInsertionStyle.allCases) { style in
                Button {
                    select(skill, style)
                } label: {
                    Label(style.label, systemImage: style.symbol)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: skill.scope == "user" ? "person.crop.circle" : "shippingbox")
                    .foregroundStyle(skill.scope == "user" ? HerdrTheme.signal : HerdrTheme.mauve)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                        .herdrFont(.subheadline, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(1)
                    Text(skill.skillFilePath)
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.mist)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Image(systemName: "plus.square.fill")
                    .herdrFont(.title3)
                    .foregroundStyle(HerdrTheme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Insert \(skill.name) skill")
        .accessibilityHint("Choose a terminal invocation style")
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
