import SwiftUI

struct JiraTicketPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let loadAssigned: () async throws -> [JiraTicket]
    let lookup: (String) async throws -> JiraTicket
    let select: (JiraTicket) -> Void

    @State private var assignedTickets: [JiraTicket] = []
    @State private var lookupQuery = ""
    @State private var lookupResult: JiraTicket?
    @State private var isLoadingAssigned = false
    @State private var isLookingUp = false
    @State private var assignedError: String?
    @State private var lookupError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                HerdrBackground()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        lookupCard

                        if let lookupResult {
                            ticketSection(title: "LOOKUP RESULT", tickets: [lookupResult])
                        }

                        assignedContent
                    }
                    .padding(.horizontal, HerdrTheme.pagePadding)
                    .padding(.vertical, 16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("JIRA CONTEXT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(HerdrTheme.graphite, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await refreshAssigned() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoadingAssigned)
                    .foregroundStyle(HerdrTheme.accent)
                    .accessibilityLabel("Refresh assigned Jira tickets")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HerdrTheme.accent)
                }
            }
            .task {
                await refreshAssigned()
            }
        }
    }

    private var lookupCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("EXACT LOOKUP")
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(HerdrTheme.mist)

            HStack(spacing: 8) {
                TextField("HERD-123 or Jira URL", text: $lookupQuery)
                    .font(.body.monospaced())
                    .foregroundStyle(HerdrTheme.text)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await performLookup() }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                    .background(HerdrTheme.graphite)
                    .overlay {
                        RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                            .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                    }
                    .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))

                Button {
                    Task { await performLookup() }
                } label: {
                    Group {
                        if isLookingUp {
                            ProgressView()
                                .tint(HerdrTheme.ink)
                        } else {
                            Image(systemName: "magnifyingglass")
                                .font(.headline.weight(.semibold))
                        }
                    }
                    .foregroundStyle(HerdrTheme.ink)
                    .frame(width: 46, height: 46)
                    .background(HerdrTheme.accent)
                    .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                }
                .buttonStyle(.plain)
                .disabled(!canLookUp)
                .opacity(canLookUp ? 1 : 0.48)
                .accessibilityLabel("Look up Jira ticket")
            }

            if let lookupError {
                Label(lookupError, systemImage: "exclamationmark.triangle")
                    .font(.caption.monospaced())
                    .foregroundStyle(HerdrTheme.alert)
            } else {
                Text("Paste a ticket key or browse URL from any project.")
                    .font(.caption.monospaced())
                    .foregroundStyle(HerdrTheme.mist)
            }
        }
        .padding(HerdrTheme.cardPadding)
        .background(HerdrTheme.elevated)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
    }

    @ViewBuilder
    private var assignedContent: some View {
        if isLoadingAssigned && assignedTickets.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(HerdrTheme.accent)
                Text("loading assigned tickets")
                    .font(.footnote.monospaced())
                    .foregroundStyle(HerdrTheme.mist)
            }
            .frame(maxWidth: .infinity, minHeight: 88)
        } else if let assignedError {
            VStack(spacing: 10) {
                Label("Jira unavailable", systemImage: "exclamationmark.triangle")
                    .font(.headline.monospaced())
                    .foregroundStyle(HerdrTheme.warning)
                Text(assignedError)
                    .font(.footnote.monospaced())
                    .foregroundStyle(HerdrTheme.mist)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await refreshAssigned() }
                }
                .buttonStyle(.borderedProminent)
                .tint(HerdrTheme.accent)
            }
            .frame(maxWidth: .infinity, minHeight: 130)
        } else if assignedTickets.isEmpty {
            ContentUnavailableView {
                Label("no assigned tickets", systemImage: "ticket")
                    .font(.headline.monospaced())
                    .foregroundStyle(HerdrTheme.text)
            } description: {
                Text("Use exact lookup for another ticket.")
                    .font(.footnote.monospaced())
                    .foregroundStyle(HerdrTheme.mist)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            ForEach(groupedTickets, id: \.project) { group in
                ticketSection(title: group.project, tickets: group.tickets)
            }
        }
    }

    private func ticketSection(title: String, tickets: [JiraTicket]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(HerdrTheme.mist)
                Spacer()
                Text("\(tickets.count)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(HerdrTheme.mist)
            }

            VStack(spacing: 0) {
                ForEach(Array(tickets.enumerated()), id: \.element.id) { index, ticket in
                    JiraTicketContextRow(
                        ticket: ticket,
                        open: { openTicket(ticket) },
                        insert: { insertTicket(ticket) }
                    )

                    if index < tickets.count - 1 {
                        Divider()
                            .overlay(HerdrTheme.surface)
                            .padding(.leading, 14)
                    }
                }
            }
            .background(HerdrTheme.elevated)
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                    .strokeBorder(HerdrTheme.surface, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
        }
    }

    private var canLookUp: Bool {
        !lookupQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLookingUp
    }

    private var groupedTickets: [(project: String, tickets: [JiraTicket])] {
        let groups = Dictionary(grouping: assignedTickets, by: projectKey)
        return groups
            .map { project, tickets in
                (
                    project: project,
                    tickets: tickets.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                )
            }
            .sorted { $0.project.localizedStandardCompare($1.project) == .orderedAscending }
    }

    private func projectKey(_ ticket: JiraTicket) -> String {
        let explicit = ticket.projectKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicit.isEmpty { return explicit }
        return ticket.key.split(separator: "-", maxSplits: 1).first.map(String.init) ?? "OTHER"
    }

    @MainActor
    private func refreshAssigned() async {
        guard !isLoadingAssigned else { return }
        isLoadingAssigned = true
        assignedError = nil

        do {
            assignedTickets = try await loadAssigned()
        } catch is CancellationError {
            return
        } catch {
            assignedError = error.localizedDescription
        }
        isLoadingAssigned = false
    }

    @MainActor
    private func performLookup() async {
        guard canLookUp else { return }
        let query = lookupQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        isLookingUp = true
        lookupError = nil
        lookupResult = nil

        do {
            lookupResult = try await lookup(query)
        } catch is CancellationError {
            return
        } catch {
            lookupError = error.localizedDescription
        }
        isLookingUp = false
    }

    private func openTicket(_ ticket: JiraTicket) {
        guard let url = URL(string: ticket.url) else { return }
        openURL(url)
    }

    private func insertTicket(_ ticket: JiraTicket) {
        select(ticket)
        dismiss()
    }
}

private struct JiraTicketContextRow: View {
    let ticket: JiraTicket
    let open: () -> Void
    let insert: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(ticket.key)
                        .font(.callout.monospaced().weight(.bold))
                        .foregroundStyle(HerdrTheme.accent)

                    statusPill(ticket.status, color: HerdrTheme.signal)

                    if !ticket.priority.isEmpty {
                        statusPill(ticket.priority, color: HerdrTheme.working)
                    }
                }

                Text(ticket.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 12)
            .padding(.leading, 14)

            VStack(spacing: 0) {
                Button(action: open) {
                    Image(systemName: "arrow.up.right")
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HerdrTheme.mist)
                .accessibilityLabel("Open \(ticket.key) in Jira")

                Button(action: insert) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HerdrTheme.signal)
                .accessibilityLabel("Insert \(ticket.key) context")
            }
        }
    }

    private func statusPill(_ value: String, color: Color) -> some View {
        Text(value.isEmpty ? "unknown" : value.lowercased())
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.11))
            .clipShape(.rect(cornerRadius: 5))
    }
}
