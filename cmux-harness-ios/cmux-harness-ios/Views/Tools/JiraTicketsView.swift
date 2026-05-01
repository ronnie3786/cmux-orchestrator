import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct JiraTicketsView: View {
    @Bindable var store: StoreOf<HarnessFeature>
    @Environment(\.openURL) private var openURL
    @State private var copiedTicketKey: String?
    @State private var copiedToastID = UUID()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            TextField("Jira key or URL", text: jiraLookupBinding)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                                .onSubmit {
                                    resolveLookup()
                                }

                            Button {
                                resolveLookup()
                            } label: {
                                if store.isResolvingJiraTicket {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 34, height: 34)
                                } else {
                                    Image(systemName: "magnifyingglass")
                                        .font(.headline.weight(.semibold))
                                        .frame(width: 34, height: 34)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canResolveLookup)
                            .accessibilityLabel("Look up Jira ticket")
                        }

                        if let error = store.jiraLookupError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Exact Lookup")
                } footer: {
                    Text("Paste a Jira key or browse URL from any project.")
                }

                if let ticket = store.resolvedJiraTicket {
                    Section("Lookup Result") {
                        JiraTicketRow(
                            ticket: ticket,
                            copyKeyAction: {
                                copyTicketKey(ticket.key)
                            },
                            openLinkAction: {
                                openJiraTicket(ticket)
                            },
                            insertAction: {
                                store.send(.appendJiraTicketReference(ticket))
                            }
                        )
                    }
                }

                assignedTicketsContent
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Jira")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .top) {
                if let copiedTicketKey {
                    JiraCopyToast(ticketKey: copiedTicketKey)
                        .padding(.top, 8)
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        store.send(.loadAssignedJiraTickets)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoadingJiraTickets)
                    .accessibilityLabel("Refresh Jira tickets")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        store.send(.dismissJiraTickets)
                    }
                }
            }
            .task {
                if store.jiraTickets.isEmpty && !store.isLoadingJiraTickets {
                    store.send(.loadAssignedJiraTickets)
                }
            }
        }
    }

    @ViewBuilder
    private var assignedTicketsContent: some View {
        if store.isLoadingJiraTickets && store.jiraTickets.isEmpty {
            Section("Assigned") {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } else if let error = store.jiraTicketsError {
            Section("Assigned") {
                ErrorBanner(message: error) {
                    store.send(.loadAssignedJiraTickets)
                }
            }
        } else if store.jiraTickets.isEmpty {
            Section("Assigned") {
                ContentUnavailableView("No Assigned Tickets", systemImage: "ticket")
            }
        } else {
            ForEach(groupedAssignedTickets, id: \.project) { group in
                Section(group.project) {
                    ForEach(group.tickets) { ticket in
                        JiraTicketRow(
                            ticket: ticket,
                            copyKeyAction: {
                                copyTicketKey(ticket.key)
                            },
                            openLinkAction: {
                                openJiraTicket(ticket)
                            },
                            insertAction: {
                                store.send(.appendJiraTicketReference(ticket))
                            }
                        )
                    }
                }
            }
        }
    }

    private var jiraLookupBinding: Binding<String> {
        Binding(
            get: { store.jiraLookupQuery },
            set: { store.send(.jiraLookupQueryChanged($0)) }
        )
    }

    private var canResolveLookup: Bool {
        !store.jiraLookupQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isResolvingJiraTicket
    }

    private var groupedAssignedTickets: [(project: String, tickets: [JiraTicket])] {
        let groups = Dictionary(grouping: store.jiraTickets) { ticket in
            projectKey(for: ticket)
        }
        return groups
            .map { project, tickets in
                (
                    project: project,
                    tickets: tickets.sorted { lhs, rhs in
                        lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
                    }
                )
            }
            .sorted { lhs, rhs in
                lhs.project.localizedCaseInsensitiveCompare(rhs.project) == .orderedAscending
            }
    }

    private func resolveLookup() {
        guard canResolveLookup else { return }
        store.send(.resolveJiraTicket)
    }

    private func projectKey(for ticket: JiraTicket) -> String {
        if let projectKey = ticket.projectKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectKey.isEmpty {
            return projectKey
        }
        return ticket.key.split(separator: "-", maxSplits: 1).first.map(String.init) ?? "Other"
    }

    private func copyTicketKey(_ key: String) {
        let toastID = UUID()
        UIPasteboard.general.string = key
        copiedToastID = toastID
        withAnimation(.easeInOut(duration: 0.18)) {
            copiedTicketKey = key
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard copiedToastID == toastID else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                copiedTicketKey = nil
            }
        }
    }

    private func openJiraTicket(_ ticket: JiraTicket) {
        guard let url = URL(string: ticket.url) else { return }
        openURL(url)
    }
}

struct JiraTicketRow: View {
    let ticket: JiraTicket
    let copyKeyAction: () -> Void
    let openLinkAction: () -> Void
    let insertAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: copyKeyAction) {
                    Text(ticket.key)
                        .font(.callout.monospaced().weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .textSelection(.disabled)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy \(ticket.key)")

                Text(ticket.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)

                VStack(alignment: .leading, spacing: 6) {
                    JiraTicketPill(text: ticket.status, systemImage: "circle.dotted")
                    if !ticket.priority.isEmpty {
                        JiraTicketPill(text: ticket.priority, systemImage: "flag")
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(spacing: 12) {
                Button(action: openLinkAction) {
                    Image(systemName: "link")
                        .font(.headline.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Open Jira ticket")

                Button(action: insertAction) {
                    Image(systemName: "text.badge.plus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .accessibilityLabel("Insert Jira ticket context")
            }
        }
        .padding(.vertical, 4)
    }
}

struct JiraTicketPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text.isEmpty ? "Unknown" : text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

struct JiraCopyToast: View {
    let ticketKey: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Copied \(ticketKey)")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 4)
    }
}
