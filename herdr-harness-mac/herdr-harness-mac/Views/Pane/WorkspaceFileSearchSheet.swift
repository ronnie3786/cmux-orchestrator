import SwiftUI

struct WorkspaceFileSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFocused: Bool

    let load: (String) async throws -> [ProjectFileMatch]
    let select: (ProjectFileMatch) -> Void

    @State private var query = ""
    @State private var results: [ProjectFileMatch] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                HerdrBackground()

                VStack(spacing: 0) {
                    searchField
                        .padding(.horizontal, HerdrTheme.pagePadding)
                        .padding(.top, 12)
                        .padding(.bottom, 10)

                    Divider()
                        .overlay(HerdrTheme.surface)

                    resultsContent
                }
            }
            .navigationTitle("WORKSPACE FILES")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HerdrTheme.accent)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .task(id: normalizedQuery) {
                await searchAfterDebounce()
            }
            .onAppear {
                isSearchFocused = true
            }
        }
        .background {
            Button("Focus Search Field") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .buttonStyle(.plain)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "at")
                .herdrFont(.subheadline, weight: .bold)
                .foregroundStyle(HerdrTheme.accent)

            TextField("Search project files", text: $query)
                .textFieldStyle(.plain)
                .herdrFont(.body, monospaced: true)
                .foregroundStyle(HerdrTheme.text)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(HerdrTheme.accent)
                    .accessibilityLabel("Searching")
            } else if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HerdrTheme.mist)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 2)
        .frame(minHeight: 48)
        .background(HerdrTheme.elevated)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(isSearchFocused ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
    }

    @ViewBuilder
    private var resultsContent: some View {
        if normalizedQuery.count < 3 {
            statePanel(
                title: "type 3+ characters",
                detail: "Paths are searched inside this pane's workspace.",
                systemImage: "doc.text.magnifyingglass"
            )
        } else if isLoading && results.isEmpty {
            statePanel(title: "searching workspace", detail: normalizedQuery, systemImage: "ellipsis")
        } else if let errorMessage {
            errorPanel(errorMessage)
        } else if results.isEmpty {
            statePanel(title: "no matching files", detail: normalizedQuery, systemImage: "doc.text")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    HStack {
                        Text("MATCHES")
                            .herdrFont(.caption2, monospaced: true, weight: .bold)
                            .foregroundStyle(HerdrTheme.mist)
                        Spacer()
                        Text("\(results.count)")
                            .herdrFont(.caption2, monospaced: true)
                            .foregroundStyle(HerdrTheme.mist)
                    }
                    .padding(.horizontal, HerdrTheme.pagePadding)
                    .padding(.vertical, 10)

                    ForEach(results) { file in
                        Button {
                            select(file)
                            dismiss()
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: "doc.text")
                                    .herdrFont(.subheadline)
                                    .foregroundStyle(HerdrTheme.accent)
                                    .frame(width: 24)

                                Text(file.path)
                                    .herdrFont(.callout, monospaced: true)
                                    .foregroundStyle(HerdrTheme.text)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Image(systemName: "plus")
                                    .herdrFont(.caption, weight: .bold)
                                    .foregroundStyle(HerdrTheme.signal)
                                    .frame(width: 44, height: 44)
                            }
                            .padding(.leading, HerdrTheme.pagePadding)
                            .padding(.trailing, 4)
                            .padding(.vertical, 4)
                            .frame(minHeight: 56)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Insert \(file.path)")

                        Divider()
                            .overlay(HerdrTheme.surface.opacity(0.75))
                            .padding(.leading, 54)
                    }
                }
            }
        }
    }

    private func statePanel(title: String, detail: String, systemImage: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
                .herdrFont(.headline, monospaced: true)
                .foregroundStyle(HerdrTheme.text)
        } description: {
            Text(detail)
                .herdrFont(.footnote, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .herdrFont(.title2)
                .foregroundStyle(HerdrTheme.warning)
            Text(message)
                .herdrFont(.footnote, monospaced: true)
                .foregroundStyle(HerdrTheme.text)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await performSearch(normalizedQuery) }
            }
            .buttonStyle(.borderedProminent)
            .tint(HerdrTheme.accent)
        }
        .padding(HerdrTheme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func searchAfterDebounce() async {
        let searchQuery = normalizedQuery
        guard searchQuery.count >= 3 else {
            isLoading = false
            errorMessage = nil
            results = []
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(275))
            try Task.checkCancellation()
            await performSearch(searchQuery)
        } catch is CancellationError {
            return
        } catch {
            guard normalizedQuery == searchQuery else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func performSearch(_ searchQuery: String) async {
        guard searchQuery.count >= 3 else { return }
        isLoading = true
        errorMessage = nil

        do {
            let loadedResults = try await load(searchQuery)
            try Task.checkCancellation()
            guard normalizedQuery == searchQuery else { return }
            results = loadedResults
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard normalizedQuery == searchQuery else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}
