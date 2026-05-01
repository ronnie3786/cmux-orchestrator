import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct GitStatusView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        List {
            Section {
                Picker("Git view", selection: gitSegmentBinding) {
                    ForEach(GitDetailSegment.allCases) { segment in
                        Text(segment.label).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
            }

            switch store.gitSegment {
            case .status:
                gitStatusSections
            case .prComments:
                GitPRCommentsSections(store: store)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            switch store.gitSegment {
            case .status:
                store.send(.gitTick)
            case .prComments:
                store.send(.loadPRComments)
            }
        }
    }

    @ViewBuilder
    private var gitStatusSections: some View {
        Group {
            if store.isLoadingGit && store.gitStatus == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let error = store.gitError {
                ErrorBanner(message: error) {
                    store.send(.gitTick)
                }
            } else if let git = store.gitStatus {
                Section("Repository") {
                    LabeledContent("Branch", value: git.branch?.isEmpty == false ? git.branch! : "Unknown")
                    LabeledContent("Path", value: git.cwd?.isEmpty == false ? git.cwd! : "No git repo")
                }

                if git.staged.isEmpty && git.unstaged.isEmpty && git.untracked.isEmpty {
                    Section {
                        ContentUnavailableView("Clean", systemImage: "checkmark.circle")
                    }
                }

                if !git.staged.isEmpty {
                    Section("Staged") {
                        ForEach(git.staged) { file in
                            GitFileRow(
                                file: file.file,
                                status: file.status,
                                section: .staged,
                                store: store
                            )
                        }
                    }
                }

                if !git.unstaged.isEmpty || !git.untracked.isEmpty {
                    Section("Unstaged") {
                        ForEach(git.unstaged) { file in
                            GitFileRow(
                                file: file.file,
                                status: file.status,
                                section: .unstaged,
                                store: store
                            )
                        }
                        ForEach(git.untracked, id: \.self) { file in
                            GitFileRow(
                                file: file,
                                status: "?",
                                section: .untracked,
                                store: store
                            )
                        }
                    }
                }

                if !git.commits.isEmpty {
                    Section("Recent Commits") {
                        ForEach(git.commits) { commit in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(commit.message)
                                    .lineLimit(2)
                                Text(commit.hash)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("No Git Data", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
    }

    private var gitSegmentBinding: Binding<GitDetailSegment> {
        Binding(
            get: { store.gitSegment },
            set: { store.send(.gitSegmentChanged($0)) }
        )
    }
}

struct GitPRCommentsSections: View {
    @Bindable var store: StoreOf<HarnessFeature>
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Toggle("Show resolved", isOn: includeResolvedBinding)
        } footer: {
            if let response = store.prCommentsResponse, response.hiddenResolvedCount > 0 {
                Text("\(response.hiddenResolvedCount) resolved thread\(response.hiddenResolvedCount == 1 ? "" : "s") hidden")
            }
        }

        if store.isLoadingPRComments && store.prCommentsResponse == nil {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
        } else if let error = store.prCommentsError {
            ErrorBanner(message: error) {
                store.send(.loadPRComments)
            }
        } else if let response = store.prCommentsResponse {
            if let pr = response.pullRequest {
                Section("Pull Request") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("#\(pr.number) \(pr.title)")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if let repo = response.repository {
                            Text("\(repo.owner)/\(repo.name)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let url = URL(string: pr.url) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open PR", systemImage: "link")
                        }
                    }
                }
            }

            if response.files.isEmpty {
                Section {
                    ContentUnavailableView(
                        response.hiddenResolvedCount > 0 ? "Only Resolved Threads" : "No PR Comments",
                        systemImage: "text.bubble",
                        description: Text(response.hiddenResolvedCount > 0 ? "Enable Show resolved to view resolved review threads." : "No code review threads were found for this branch.")
                    )
                }
            } else {
                ForEach(response.files) { fileGroup in
                    Section(fileGroup.path) {
                        ForEach(fileGroup.threads) { thread in
                            GitPRThreadRow(
                                thread: thread,
                                copyAction: {
                                    UIPasteboard.general.string = thread.promptReference(pullRequest: response.pullRequest)
                                },
                                openAction: {
                                    if let url = URL(string: thread.url) {
                                        openURL(url)
                                    }
                                },
                                insertAction: {
                                    store.send(.appendPRCommentThread(thread))
                                },
                                requestFixAction: {
                                    store.send(.requestFixForPRCommentThread(thread))
                                }
                            )
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("No PR Data", systemImage: "text.bubble")
        }
    }

    private var includeResolvedBinding: Binding<Bool> {
        Binding(
            get: { store.includeResolvedPRComments },
            set: { store.send(.setPRCommentsIncludeResolved($0)) }
        )
    }
}

struct GitPRThreadRow: View {
    let thread: GitHubPRThread
    let copyAction: () -> Void
    let openAction: () -> Void
    let insertAction: () -> Void
    let requestFixAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Label(thread.lineLabel, systemImage: "number")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                if thread.isResolved {
                    GitPRThreadPill(text: "Resolved", systemImage: "checkmark.circle")
                }
                if thread.isOutdated {
                    GitPRThreadPill(text: "Outdated", systemImage: "clock")
                }

                Spacer(minLength: 8)

                Button(action: insertAction) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .accessibilityLabel("Insert PR comment thread")

                Button(action: copyAction) {
                    Image(systemName: "doc.on.doc")
                        .font(.headline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Copy PR comment thread")

                if !thread.url.isEmpty {
                    Button(action: openAction) {
                        Image(systemName: "link")
                            .font(.headline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Open PR comment thread")
                }
            }

            if let codeContext = thread.codeContext, !codeContext.lines.isEmpty {
                GitPRCodeContextView(context: codeContext)
            }

            ForEach(thread.comments) { comment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(comment.author.isEmpty ? "unknown" : comment.author)
                            .font(.caption.weight(.bold))
                        if !comment.createdAt.isEmpty {
                            Text(comment.createdAt)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Text(comment.body)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Button(action: requestFixAction) {
                Label("Request fix", systemImage: "paperplane.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityLabel("Request fix for PR comment thread")
        }
        .padding(.vertical, 5)
    }
}

struct GitPRCodeContextView: View {
    let context: GitHubPRCodeContext

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(context.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(line.number)")
                            .foregroundStyle(line.isTarget ? Color.accentColor : Color.secondary)
                            .frame(width: 42, alignment: .trailing)

                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.system(size: 12, weight: line.isTarget ? .semibold : .regular, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        line.isTarget ? Color.accentColor.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
                }
            }
            .padding(8)
        }
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }
}

struct GitPRThreadPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

struct GitFileRow: View {
    let file: String
    let status: String
    let section: GitFileSection
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        HStack(spacing: 10) {
            Text(status)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(section == .staged ? .green : .orange)
                .frame(width: 24)

            Text(file)
                .font(.callout.monospaced())
                .lineLimit(2)

            Spacer()

            Button {
                store.send(.requestDiff(file: file, section: section))
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderless)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                store.send(.requestDiff(file: file, section: section))
            } label: {
                Label("Diff", systemImage: "doc.text.magnifyingglass")
            }
            .tint(.blue)

            if section == .staged {
                Button {
                    store.send(.unstageFile(file))
                } label: {
                    Label("Unstage", systemImage: "minus.circle")
                }
                .tint(.orange)
            } else {
                Button {
                    store.send(.stageFile(file))
                } label: {
                    Label("Stage", systemImage: "plus.circle")
                }
                .tint(.green)
            }
        }
        .contextMenu {
            Button {
                store.send(.requestDiff(file: file, section: section))
            } label: {
                Label("View Diff", systemImage: "doc.text.magnifyingglass")
            }

            if section == .staged {
                Button {
                    store.send(.unstageFile(file))
                } label: {
                    Label("Unstage File", systemImage: "minus.circle")
                }
            } else {
                Button {
                    store.send(.stageFile(file))
                } label: {
                    Label("Stage File", systemImage: "plus.circle")
                }
            }
        }
    }
}
