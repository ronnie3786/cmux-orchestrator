import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ActivityListView: View {
    let entries: [LogEntry]

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView("No Activity", systemImage: "list.bullet.rectangle")
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.action ?? "Activity")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if let timestamp = entry.timestamp {
                                Text(formatTimestamp(timestamp))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let promptType = entry.promptType, !promptType.isEmpty {
                            Text(promptType)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let reason = entry.reason, !reason.isEmpty {
                            Text(reason)
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct SkillsListView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        List {
            if store.isLoadingSkills && !store.hasSkills {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let error = store.skillsError {
                ErrorBanner(message: error) {
                    store.send(.loadSkills)
                }
            } else if !store.hasSkills {
                ContentUnavailableView("No Skills", systemImage: "wand.and.stars")
            } else {
                if !store.projectSkills.isEmpty {
                    Section("Project Skills") {
                        ForEach(store.projectSkills) { skill in
                            SkillMenuRow(store: store, skill: skill)
                        }
                    }
                }

                if !store.userSkills.isEmpty {
                    Section("User Skills") {
                        ForEach(store.userSkills) { skill in
                            SkillMenuRow(store: store, skill: skill)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            store.send(.loadSkills)
        }
    }
}

struct SkillMenuRow: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let skill: ProjectSkill

    var body: some View {
        Menu {
            Button {
                store.send(.appendSkillInvocation(skill))
            } label: {
                Label("Claude Code", systemImage: "terminal")
            }

            Button {
                store.send(.appendCodexSkillInvocation(skill))
            } label: {
                Label("Codex CLI", systemImage: "dollarsign.circle")
            }

            Button {
                store.send(.appendSkillFilePath(skill))
            } label: {
                Label("File Path", systemImage: "doc.text")
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(skill.skillFilePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Image(systemName: "plus.circle.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.gray)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct FileSearchView: View {
    @Bindable var store: StoreOf<HarnessFeature>
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search project files", text: fileSearchBinding)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isSearchFocused)
                }

                if store.fileSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 {
                    ContentUnavailableView("Search Files", systemImage: "at")
                } else if store.isSearchingFiles && store.fileSearchResults.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if let error = store.fileSearchError {
                    ErrorBanner(message: error) {
                        store.send(.fileSearchQueryChanged(store.fileSearchQuery))
                    }
                } else if store.fileSearchResults.isEmpty {
                    ContentUnavailableView("No Matches", systemImage: "doc.text.magnifyingglass")
                } else {
                    ForEach(store.fileSearchResults) { file in
                        Button {
                            store.send(.appendFilePath(file))
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24)
                                Text(file.path)
                                    .font(.callout.monospaced())
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        store.send(.dismissFileSearch)
                    }
                }
            }
            .onAppear {
                isSearchFocused = true
            }
        }
    }

    private var fileSearchBinding: Binding<String> {
        Binding(
            get: { store.fileSearchQuery },
            set: { store.send(.fileSearchQueryChanged($0)) }
        )
    }
}
