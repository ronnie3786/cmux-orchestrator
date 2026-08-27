import SwiftUI

struct WorkspaceGitView: View {
    let workspace: HerdrWorkspace
    let loadStatus: () async throws -> WorkspaceGitStatus
    let loadDiff: (String, GitFileSection) async throws -> WorkspaceGitDiffResponse
    let stageFile: (String) async throws -> Void
    let unstageFile: (String) async throws -> Void

    @State private var status: WorkspaceGitStatus?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pendingFiles: Set<String> = []
    @State private var selectedDiff: WorkspaceGitDiffTarget?
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                repositoryHeader

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if isLoading, status == nil {
                            loadingCard
                        } else if let errorMessage, status == nil {
                            errorCard(errorMessage)
                        } else if let status {
                            gitContent(status)
                        } else {
                            emptyCard(
                                title: "No Git data",
                                detail: "This workspace does not have a Git repository yet.",
                                symbol: PaneDetailMode.git.symbol
                            )
                        }
                    }
                    .padding(12)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.visible)
            }
            .frame(minWidth: 270, idealWidth: 320, maxWidth: 380, maxHeight: .infinity)
            .background(HerdrTheme.graphite.opacity(0.45))

            Rectangle()
                .fill(HerdrTheme.surface)
                .frame(width: 1)

            WorkspaceGitDiffView(target: selectedDiff, loadDiff: loadDiff)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: workspace.id) { await refresh() }
        .herdrHaptic(trigger: hapticPulse)
    }

    private var repositoryHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: PaneDetailMode.git.symbol)
                    .foregroundStyle(HerdrTheme.mauve)

                Text(status?.branch?.nonEmpty ?? workspace.tokens["branch"]?.nonEmpty ?? "detached")
                    .herdrFont(.headline, monospaced: true, weight: .bold)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let status {
                    Text(status.hasChanges ? "\(status.changeCount) changed" : "clean")
                        .herdrFont(.caption, monospaced: true, weight: .bold)
                        .foregroundStyle(status.hasChanges ? HerdrTheme.working : HerdrTheme.success)
                }

                Button("Refresh Git", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .foregroundStyle(HerdrTheme.accent)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(isLoading)
                .symbolEffect(.rotate, options: .repeating, isActive: isLoading)
            }

            Text(status?.cwd?.nonEmpty ?? workspace.displayPath)
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(HerdrTheme.graphite)
        .overlay(alignment: .bottom) { Rectangle().fill(HerdrTheme.surface).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workspace-git")
    }

    @ViewBuilder
    private func gitContent(_ git: WorkspaceGitStatus) -> some View {
        if let errorMessage {
            errorCard(errorMessage)
        }

        if !git.hasChanges {
            emptyCard(
                title: "Working tree clean",
                detail: "Everything in this workspace is committed.",
                symbol: "checkmark.circle.fill"
            )
        }

        if !git.staged.isEmpty {
            GitFileSectionView(
                title: "staged",
                count: git.staged.count,
                files: git.staged,
                section: .staged,
                pendingFiles: pendingFiles,
                selectedDiff: selectedDiff,
                selectDiff: selectDiff,
                mutate: mutate
            )
        }

        if !git.unstaged.isEmpty {
            GitFileSectionView(
                title: "unstaged",
                count: git.unstaged.count,
                files: git.unstaged,
                section: .unstaged,
                pendingFiles: pendingFiles,
                selectedDiff: selectedDiff,
                selectDiff: selectDiff,
                mutate: mutate
            )
        }

        if !git.untracked.isEmpty {
            GitFileSectionView(
                title: "untracked",
                count: git.untracked.count,
                files: git.untracked.map { WorkspaceGitFile(status: "?", file: $0) },
                section: .untracked,
                pendingFiles: pendingFiles,
                selectedDiff: selectedDiff,
                selectDiff: selectDiff,
                mutate: mutate
            )
        }

        if !git.commits.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                GitSectionHeader(title: "recent commits", count: git.commits.count)

                ForEach(Array(git.commits.enumerated()), id: \.element.id) { index, commit in
                    GitCommitRow(commit: commit)
                    if index < git.commits.count - 1 {
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

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(HerdrTheme.accent)
            Text("Reading workspace Git state…")
                .herdrFont(.subheadline, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Git unavailable", systemImage: "exclamationmark.triangle.fill")
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

    private func emptyCard(title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .herdrFont(.title2)
                .foregroundStyle(symbol.hasPrefix("checkmark") ? HerdrTheme.success : HerdrTheme.mist)
            Text(title)
                .herdrFont(.subheadline, monospaced: true, weight: .bold)
                .foregroundStyle(HerdrTheme.text)
            Text(detail)
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 124)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
    }

    private func selectDiff(file: String, section: GitFileSection) {
        selectedDiff = WorkspaceGitDiffTarget(file: file, section: section)
    }

    private func mutate(file: String, section: GitFileSection) {
        guard !pendingFiles.contains(file) else { return }
        pendingFiles.insert(file)
        errorMessage = nil
        Task {
            do {
                if section == .staged {
                    try await unstageFile(file)
                } else {
                    try await stageFile(file)
                }
                await refresh()
                hapticPulse.fire(section == .staged ? .gitUnstaged : .gitStaged)
            } catch {
                errorMessage = error.localizedDescription
                hapticPulse.fire(.failed)
            }
            pendingFiles.remove(file)
        }
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let refreshedStatus = try await loadStatus()
            status = refreshedStatus
            errorMessage = refreshedStatus.error
            reconcileSelection(with: refreshedStatus)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reconcileSelection(with status: WorkspaceGitStatus) {
        let targets = status.staged.map { WorkspaceGitDiffTarget(file: $0.file, section: .staged) }
            + status.unstaged.map { WorkspaceGitDiffTarget(file: $0.file, section: .unstaged) }
            + status.untracked.map { WorkspaceGitDiffTarget(file: $0, section: .untracked) }
        if let selectedDiff, targets.contains(where: { $0.id == selectedDiff.id }) { return }
        selectedDiff = targets.first
    }
}

private struct GitFileSectionView: View {
    let title: String
    let count: Int
    let files: [WorkspaceGitFile]
    let section: GitFileSection
    let pendingFiles: Set<String>
    let selectedDiff: WorkspaceGitDiffTarget?
    let selectDiff: (String, GitFileSection) -> Void
    let mutate: (String, GitFileSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GitSectionHeader(title: title, count: count)

            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                GitFileRow(
                    file: file,
                    section: section,
                    isPending: pendingFiles.contains(file.file),
                    isSelected: selectedDiff?.id == WorkspaceGitDiffTarget(file: file.file, section: section).id,
                    selectDiff: selectDiff,
                    mutate: mutate
                )
                if index < files.count - 1 {
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

private struct GitSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .bold()
                .underline()
            Spacer()
            Text("\(count)")
        }
        .herdrFont(.caption, monospaced: true)
        .foregroundStyle(HerdrTheme.mist)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(HerdrTheme.elevated)
        .accessibilityElement(children: .combine)
    }
}

private struct GitFileRow: View {
    let file: WorkspaceGitFile
    let section: GitFileSection
    let isPending: Bool
    let isSelected: Bool
    let selectDiff: (String, GitFileSection) -> Void
    let mutate: (String, GitFileSection) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(file.status)
                .herdrFont(.caption, monospaced: true, weight: .bold)
                .foregroundStyle(section == .staged ? HerdrTheme.success : HerdrTheme.working)
                .frame(width: 22)

            Button {
                selectDiff(file.file, section)
            } label: {
                Text(file.file)
                    .herdrFont(.callout, monospaced: true)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityLabel("View diff for \(file.file)")

            Button(section == .staged ? "Unstage" : "Stage") {
                mutate(file.file, section)
            }
            .buttonStyle(.plain)
            .herdrFont(.caption, monospaced: true, weight: .bold)
            .foregroundStyle(section == .staged ? HerdrTheme.warning : HerdrTheme.success)
            .frame(minWidth: 56, minHeight: 44)
            .disabled(isPending)
            .overlay {
                if isPending {
                    ProgressView().tint(HerdrTheme.accent)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(isSelected ? HerdrTheme.accent.opacity(0.12) : .clear)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? HerdrTheme.accent : .clear)
                .frame(width: 3)
        }
    }
}

private struct GitCommitRow: View {
    let commit: WorkspaceGitCommit

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(commit.hash)
                .herdrFont(.caption, monospaced: true, weight: .bold)
                .foregroundStyle(HerdrTheme.mauve)
                .lineLimit(1)

            Text(commit.message)
                .herdrFont(.callout)
                .foregroundStyle(HerdrTheme.text)
                .lineLimit(3)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

private struct WorkspaceGitDiffTarget: Identifiable {
    let file: String
    let section: GitFileSection

    var id: String { "\(section.rawValue)|\(file)" }
}

private struct WorkspaceGitDiffView: View {
    let target: WorkspaceGitDiffTarget?
    let loadDiff: (String, GitFileSection) async throws -> WorkspaceGitDiffResponse
    @State private var diff: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(target?.section.label.lowercased() ?? "code changes")
                        .herdrFont(.caption2, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.mist)
                    Text(target?.file ?? "Select a changed file")
                        .herdrFont(.subheadline, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .background(HerdrTheme.graphite)
            .overlay(alignment: .bottom) { Rectangle().fill(HerdrTheme.surface).frame(height: 1) }

            ZStack {
                HerdrBackground()

                if target == nil {
                    ContentUnavailableView(
                        "Select a changed file",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Its diff will stay open here while you browse the repository.")
                    )
                    .foregroundStyle(HerdrTheme.text)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Diff unavailable",
                        systemImage: "exclamationmark.triangle.fill",
                        description: Text(errorMessage)
                    )
                    .foregroundStyle(HerdrTheme.text)
                } else if let diff {
                    GeometryReader { proxy in
                        ScrollView([.horizontal, .vertical]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(diffLines(diff).enumerated()), id: \.offset) { _, line in
                                    Text(line.isEmpty ? " " : line)
                                        .herdrFont(.caption, monospaced: true)
                                        .foregroundStyle(diffColor(line))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(diffBackground(line))
                                }
                            }
                            .frame(
                                minWidth: proxy.size.width,
                                minHeight: proxy.size.height,
                                alignment: .topLeading
                            )
                            .padding(.vertical, 10)
                            .textSelection(.enabled)
                        }
                        .defaultScrollAnchor(.topLeading, for: .alignment)
                    }
                } else {
                    ProgressView("Loading diff…")
                        .herdrFont(.subheadline, monospaced: true)
                        .tint(HerdrTheme.accent)
                        .foregroundStyle(HerdrTheme.mist)
                }
            }
        }
        .task(id: target?.id) {
            diff = nil
            errorMessage = nil
            guard let target else { return }
            do {
                let response = try await loadDiff(target.file, target.section)
                if let responseError = response.error {
                    errorMessage = responseError
                } else {
                    diff = response.diff?.nonEmpty ?? "(empty diff)"
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-diff")
    }

    private func diffLines(_ value: String) -> [String] {
        value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func diffColor(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return HerdrTheme.success }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return HerdrTheme.alert }
        if line.hasPrefix("@@") { return HerdrTheme.mauve }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") { return HerdrTheme.accent }
        return HerdrTheme.text
    }

    private func diffBackground(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return HerdrTheme.success.opacity(0.10) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return HerdrTheme.alert.opacity(0.10) }
        if line.hasPrefix("@@") { return HerdrTheme.mauve.opacity(0.10) }
        return .clear
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
