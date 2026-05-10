import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor
    @AppStorage("cmuxHarnessMacOnboardingComplete") private var onboardingComplete = false
    @AppStorage("cmuxHarnessMacServerPort") private var serverPort = 9091
    @AppStorage("cmuxHarnessMacLaunchServerAtAppStart") private var launchServerAtAppStart = true
    @AppStorage("cmuxHarnessMacKeepServerRunningAfterWindowClose") private var keepServerRunningAfterWindowClose = false
    @AppStorage("cmuxHarnessMacAutoRestartServer") private var autoRestartServer = true
    @State private var detailTab: DetailTab = .terminal
    @State private var inspectorTab: InspectorTab = .git
    @State private var isShowingNewSession = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 260)
        } detail: {
            VStack(spacing: 0) {
                ServerHealthStrip()
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        DetailToolbar(detailTab: $detailTab)
                        Divider()
                        detailContent
                    }
                    .frame(minWidth: 520)

                    Divider()

                    InspectorView(selectedTab: $inspectorTab)
                        .frame(minWidth: 340, idealWidth: 420)
                }
            }
        }
        .navigationTitle("cmux Harness")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await appState.refresh(supervisor: supervisor) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")

                Button {
                    isShowingNewSession = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("New Session")

                Menu {
                    Button("Start Server") { supervisor.start(port: serverPort) }
                    Button("Stop Server") { supervisor.stop() }
                    Button("Restart Server") { supervisor.restart(port: serverPort) }
                    Divider()
                    Button("Open Browser Dashboard") { supervisor.openBrowserDashboard() }
                    Button("Copy iPhone URL") { supervisor.copyIPhoneURL() }
                    Button("Open cmux") { supervisor.openCmux() }
                } label: {
                    Image(systemName: "server.rack")
                }
                .help("Server Actions")
            }
        }
        .task {
            supervisor.autoRestart = autoRestartServer
            appState.start(supervisor: supervisor, launchManagedServer: launchServerAtAppStart, preferredPort: serverPort)
        }
        .onDisappear {
            appState.stop()
            if !keepServerRunningAfterWindowClose {
                supervisor.stop()
            }
        }
        .sheet(isPresented: Binding(
            get: { !onboardingComplete },
            set: { if !$0 { onboardingComplete = true } }
        )) {
            MacOnboardingView(onboardingComplete: $onboardingComplete)
                .environmentObject(appState)
                .environmentObject(supervisor)
        }
        .sheet(isPresented: $isShowingNewSession) {
            NewSessionView(isPresented: $isShowingNewSession)
                .environmentObject(appState)
                .environmentObject(supervisor)
        }
        .sheet(isPresented: Binding(
            get: { appState.renameWorkspaceID != nil },
            set: { if !$0 { appState.renameWorkspaceID = nil } }
        )) {
            RenameWorkspaceView()
                .environmentObject(appState)
                .environmentObject(supervisor)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch detailTab {
        case .terminal:
            TerminalDetailView()
        case .feed:
            FeedView()
        case .logs:
            LogView()
        case .settings:
            SettingsView()
        }
    }
}

struct MacOnboardingView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor
    @Binding var onboardingComplete: Bool
    @AppStorage("cmuxHarnessMacServerPort") private var serverPort = 9091

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "macwindow.and.cursorarrow")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 6) {
                    Text("cmux Harness")
                        .font(.largeTitle.bold())
                    Text("Connect to your Mac.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("Start the managed dashboard server on this Mac, connect to another harness URL, or explore with local demo data.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("Try Local Demo Mode", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.headline)
                Text("No cmux server required. Shows simulated cmux sessions, terminal output, Git, GitHub, Jira, files, skills, attachments, and voice notes.")
                    .foregroundStyle(.secondary)
                Button {
                    appState.switchMode(.localDemo, supervisor: supervisor)
                    onboardingComplete = true
                } label: {
                    Label("Start Local Demo", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 12) {
                Label("Use Managed Server", systemImage: "server.rack")
                    .font(.headline)
                Text("Launches dashboard.py in the background, keeps browser and iPhone APIs available, and connects to the cmux Automation socket when cmux is running.")
                    .foregroundStyle(.secondary)
                Button {
                    appState.switchMode(.managedServer, supervisor: supervisor, preferredPort: serverPort)
                    onboardingComplete = true
                } label: {
                    Label("Start Managed Server", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 12) {
                Label("Use Local Server URL", systemImage: "link")
                    .font(.headline)
                Text("Enter the URL for a computer running the cmux dashboard. Use localhost from this Mac, or a LAN/Tailscale URL for another Mac.")
                    .foregroundStyle(.secondary)
                TextField("your-mac.local:9091/harness", text: $appState.serverURLString)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task {
                        await appState.useExternalServerURL(appState.serverURLString, supervisor: supervisor)
                        if appState.serverSetupError == nil {
                            onboardingComplete = true
                        }
                    }
                } label: {
                    Label("Use Server URL", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 12) {
                Label("Optional Tailscale", systemImage: "network")
                    .font(.headline)
                Text("Enter a MagicDNS host or Tailscale IP. Bonjour scan only finds harness servers advertising on the local network.")
                    .foregroundStyle(.secondary)
                TextField("100.89.178.110 or your-mac.your-tailnet.ts.net", text: $appState.tailscaleHostString)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 12) {
                    Button {
                        Task {
                            await appState.tryTailscaleHost(supervisor: supervisor)
                            if appState.serverSetupError == nil {
                                onboardingComplete = true
                            }
                        }
                    } label: {
                        Label("Try Host/IP", systemImage: "network")
                            .frame(maxWidth: .infinity)
                    }

                    Button {
                        Task { await appState.discoverServers() }
                    } label: {
                        Label("Scan Bonjour LAN", systemImage: "dot.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

            if appState.isDiscoveringServer {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(appState.serverSetupMessage ?? "Looking for server...")
                        .font(.subheadline.weight(.semibold))
                }
            } else if !appState.discoveredServers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Discovered servers")
                        .font(.headline)
                    ForEach(appState.discoveredServers) { server in
                        Button {
                            Task {
                                await appState.useDiscoveredServer(server, supervisor: supervisor)
                                if appState.serverSetupError == nil {
                                    onboardingComplete = true
                                }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(server.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text(server.urlString)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.right.circle.fill")
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let message = appState.serverSetupMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let error = appState.serverSetupError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("You can switch modes later from the toolbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Skip") {
                    onboardingComplete = true
                }
            }
        }
        .padding(28)
        .frame(width: 640)
    }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case feed = "Feed"
    case logs = "Logs"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .terminal:
            "terminal"
        case .feed:
            "checklist"
        case .logs:
            "list.bullet.rectangle"
        case .settings:
            "gearshape"
        }
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case git = "Git"
    case pr = "PR"
    case jira = "Jira"
    case files = "Files"
    case skills = "Skills"
    case attachments = "Attach"
    case activity = "Activity"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .git:
            "point.3.connected.trianglepath.dotted"
        case .pr:
            "text.bubble"
        case .jira:
            "ticket"
        case .files:
            "doc.text.magnifyingglass"
        case .skills:
            "wand.and.stars"
        case .attachments:
            "paperclip"
        case .activity:
            "waveform.path.ecg"
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor
    @State private var isShowingVoiceRecorder = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Sessions", systemImage: "rectangle.stack")
                        .font(.headline)
                    Spacer()
                    CountBadge(value: appState.workspaces.count)
                }

                TextField("Search sessions", text: $appState.searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(appState.visibleWorkspaces) { workspace in
                        SessionRow(
                            workspace: workspace,
                            isSelected: workspace.id == appState.selectedWorkspaceID
                        )
                        .onTapGesture {
                            appState.selectedWorkspaceID = workspace.id
                            appState.screenText = workspace.screenFull ?? workspace.screenTail ?? appState.screenText
                        }
                        .contextMenu {
                            Button("Rename...") {
                                appState.beginRename(workspace)
                            }
                            Button(workspace.starred == true ? "Unstar" : "Star") {
                                Task { await appState.toggleStar(workspace, supervisor: supervisor) }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct SessionRow: View {
    var workspace: Workspace
    var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.opacity(isSelected ? 0.22 : 0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(workspace.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if workspace.starred == true {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(workspace.branch?.isEmpty == false ? workspace.branch! : workspace.cwd ?? "No working directory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    ModeChip(mode: workspace.resolvedAutoMode)
                    if workspace.gitDirty == true {
                        MetadataChip(text: "dirty", color: .orange)
                    }
                    if let cost = workspace.sessionCost, !cost.isEmpty {
                        MetadataChip(text: cost, color: .secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.24) : Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private var icon: String {
        workspace.hasClaude == true ? "sparkles" : "terminal"
    }

    private var color: Color {
        switch workspace.resolvedAutoMode {
        case .off:
            .secondary
        case .auto:
            .green
        case .superAuto:
            .orange
        }
    }
}

struct ServerHealthStrip: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor
    @AppStorage("cmuxHarnessMacServerPort") private var serverPort = 9091

    var body: some View {
        HStack(spacing: 10) {
            Picker("Mode", selection: Binding(
                get: { appState.mode },
                set: { appState.switchMode($0, supervisor: supervisor, preferredPort: serverPort) }
            )) {
                ForEach(HarnessMode.allCases) { mode in
                    Text(mode.shortLabel).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 232)

            Divider()
                .frame(height: 18)

            StatusPill(title: "Server", value: appState.mode == .localDemo ? "Demo" : supervisor.phase.label, color: serverColor)
            StatusPill(title: "cmux", value: cmuxLabel, color: cmuxColor)
            StatusPill(title: "Socket", value: appState.status.socketFound == true ? "Found" : "Missing", color: appState.status.socketFound == true ? .green : .orange)

            Toggle(isOn: Binding(
                get: { appState.status.enabled == true },
                set: { value in Task { await appState.setGlobalEnabled(value, supervisor: supervisor) } }
            )) {
                Text("Global Auto")
                    .lineLimit(1)
            }
            .toggleStyle(.switch)
            .font(.caption)

            Text(appState.mode == .externalServer ? appState.committedServerURLString : supervisor.baseURLString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let error = appState.errorMessage ?? supervisor.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var serverColor: Color {
        if appState.mode == .localDemo { return .blue }
        return supervisor.phase.isRunning ? .green : .orange
    }

    private var cmuxLabel: String {
        appState.status.connected == true ? "Connected" : "Waiting"
    }

    private var cmuxColor: Color {
        appState.status.connected == true ? .green : .orange
    }
}

extension HarnessMode {
    var shortLabel: String {
        switch self {
        case .managedServer:
            "Managed"
        case .externalServer:
            "External"
        case .localDemo:
            "Demo"
        }
    }
}

struct RenameWorkspaceView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Session")
                .font(.title2.bold())
            TextField("Session name", text: $appState.renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task { await appState.commitRename(supervisor: supervisor) }
                }
            HStack {
                Spacer()
                Button("Cancel") {
                    appState.renameWorkspaceID = nil
                }
                Button("Rename") {
                    Task { await appState.commitRename(supervisor: supervisor) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

struct StatusPill: View {
    var title: String
    var value: String
    var color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.caption)
    }
}

struct CountBadge: View {
    var value: Int

    var body: some View {
        Text("\(value)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }
}

struct MetadataChip: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption2.monospaced().weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct ModeChip: View {
    var mode: WorkspaceAutoMode

    var body: some View {
        MetadataChip(text: mode.label, color: color)
    }

    private var color: Color {
        switch mode {
        case .off:
            .secondary
        case .auto:
            .green
        case .superAuto:
            .orange
        }
    }
}

struct DetailToolbar: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor
    @Binding var detailTab: DetailTab

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let workspace = appState.selectedWorkspace {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(workspace.resolvedAutoMode == .off ? Color.secondary.opacity(0.12) : Color.green.opacity(0.14))
                            .frame(width: 36, height: 36)
                        Image(systemName: workspace.hasClaude == true ? "sparkles" : "terminal")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(workspace.resolvedAutoMode == .off ? Color.secondary : Color.green)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workspace.displayName)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text([workspace.cwd, workspace.branch].compactMap { value in
                            guard let value, !value.isEmpty else { return nil }
                            return value
                        }.joined(separator: "  •  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                }
            } else {
                Text("No session selected")
                    .font(.headline)
            }

            HStack(spacing: 10) {
                Picker("Auto Mode", selection: Binding(
                    get: { appState.selectedWorkspace?.resolvedAutoMode ?? .off },
                    set: { newValue in Task { await appState.setAutoMode(newValue, supervisor: supervisor) } }
                )) {
                    ForEach(WorkspaceAutoMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 168)
                .disabled(appState.selectedWorkspace == nil)

                Spacer(minLength: 8)

                Picker("Detail", selection: $detailTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(minWidth: 270, idealWidth: 320, maxWidth: 340)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct NewSessionView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("New Session")
                    .font(.title2.bold())
                Spacer()
                Picker("Mode", selection: $appState.newSessionMode) {
                    ForEach(NewSessionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            Form {
                TextField("Project path", text: $appState.newSessionProjectPath)
                if appState.newSessionMode == .shell {
                    TextField("Session name", text: $appState.newSessionName)
                } else {
                    TextField("Branch name", text: $appState.newSessionBranchName)
                    TextField("Jira URL", text: $appState.newSessionJiraURL)
                    TextField("Prompt", text: $appState.newSessionPrompt, axis: .vertical)
                        .lineLimit(4...8)
                }
            }
            .formStyle(.grouped)

            if let error = appState.newSessionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                Button(appState.isCreatingSession ? "Creating..." : "Create") {
                    Task {
                        await appState.createNewSession(supervisor: supervisor)
                        if appState.newSessionError == nil {
                            isPresented = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isCreatingSession)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

struct TerminalDetailView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor
    @State private var isShowingVoiceRecorder = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(appState.screenText.isEmpty ? "No terminal output yet." : appState.screenText)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(18)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.96))

            Divider()

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    KeyCommandButton(title: "Enter", systemImage: "return") {
                        Task { await appState.sendKey("enter", supervisor: supervisor) }
                    }
                    KeyCommandButton(title: "Tab", systemImage: "arrow.right.to.line") {
                        Task { await appState.sendKey("tab", supervisor: supervisor) }
                    }
                    KeyCommandButton(title: "Up", systemImage: "arrow.up") {
                        Task { await appState.sendKey("up", supervisor: supervisor) }
                    }
                    KeyCommandButton(title: "Down", systemImage: "arrow.down") {
                        Task { await appState.sendKey("down", supervisor: supervisor) }
                    }
                    Spacer()
                    Button {
                        isShowingVoiceRecorder = true
                    } label: {
                        Label("Voice", systemImage: "mic.fill")
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 8) {
                    TextField("Send prompt to selected session", text: $appState.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                        }
                        .onSubmit {
                            Task { await appState.sendDraft(supervisor: supervisor) }
                        }
                    Button {
                        Task { await appState.sendDraft(supervisor: supervisor) }
                    } label: {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        }
        .sheet(isPresented: $isShowingVoiceRecorder) {
            VoiceNoteRecorderSheet(isPresented: $isShowingVoiceRecorder) { url in
                Task { await appState.addAttachment(url, supervisor: supervisor) }
            }
        }
    }
}

struct KeyCommandButton: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(minWidth: 72)
        }
        .buttonStyle(.bordered)
        .help("Send \(title)")
    }
}

struct VoiceNoteRecorderSheet: View {
    @StateObject private var recorder = VoiceNoteRecorder()
    @Binding var isPresented: Bool
    let saveAction: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Voice Note")
                    .font(.title2.bold())
                Spacer()
                Text(formattedDuration(recorder.elapsedTime))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button {
                recorder.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(recorder.isRecording ? Color.red : Color.accentColor)
                        .frame(width: 96, height: 96)
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")

            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            if recorder.status == .finished {
                HStack(spacing: 10) {
                    Button {
                        recorder.togglePlayback()
                    } label: {
                        Label(recorder.isPlaying ? "Pause Preview" : "Play Preview", systemImage: recorder.isPlaying ? "pause.fill" : "play.fill")
                    }
                    ProgressView(value: recorder.playbackProgress)
                }
            }

            if let error = recorder.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            HStack {
                Button(role: recorder.hasStartedRecording ? .destructive : nil) {
                    if recorder.hasStartedRecording {
                        recorder.discard()
                    } else {
                        isPresented = false
                    }
                } label: {
                    Label(recorder.hasStartedRecording ? "Discard" : "Close", systemImage: recorder.hasStartedRecording ? "trash" : "xmark")
                }

                Spacer()

                Button {
                    guard let url = recorder.outputURL, recorder.canSave else { return }
                    saveAction(url)
                    recorder.resetAfterSaving()
                    isPresented = false
                } label: {
                    Label("Attach Voice Note", systemImage: "paperclip")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!recorder.canSave)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onDisappear {
            if !recorder.canSave {
                recorder.discard()
            }
        }
    }

    private var statusText: String {
        switch recorder.status {
        case .idle:
            return "Tap the microphone to start. Limit \(formattedDuration(VoiceNoteRecorder.maxDuration))."
        case .recording:
            return "Recording. Tap stop when finished."
        case .finished:
            return "Preview or attach this recording."
        }
    }
}

private func formattedDuration(_ duration: TimeInterval) -> String {
    let total = max(0, Int(duration.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
}

struct FeedView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor

    var body: some View {
        List {
            if appState.feedItems.isEmpty {
                ContentUnavailableView("No Feed Requests", systemImage: "checkmark.circle", description: Text("Open approval, plan, and question requests appear here."))
            }
            ForEach(appState.feedItems) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(item.displayTitle, systemImage: icon(for: item.kind))
                            .font(.headline)
                        Spacer()
                        Text(item.kind)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(item.summary)
                        .font(.subheadline)
                        .textSelection(.enabled)
                    if let command = item.command, !command.isEmpty {
                        Text(command)
                            .font(.caption.monospaced())
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("Approve") {
                            Task { await appState.replyToFeed(item, action: "approve", supervisor: supervisor) }
                        }
                        Button("Deny") {
                            Task { await appState.replyToFeed(item, action: "deny", supervisor: supervisor) }
                        }
                        Spacer()
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "permission":
            "lock.open"
        case "plan":
            "list.clipboard"
        case "question":
            "questionmark.circle"
        default:
            "tray"
        }
    }
}

struct InspectorView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor
    @Binding var selectedTab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabBar(selectedTab: $selectedTab)

            Divider()

            Group {
                switch selectedTab {
                case .git:
                    GitInspectorView()
                case .pr:
                    PRCommentsView()
                case .jira:
                    JiraView()
                case .files:
                    FilesInspectorView()
                case .skills:
                    SkillsInspectorView()
                case .attachments:
                    AttachmentsView()
                case .activity:
                    ActivityInspectorView()
                }
            }
        }
    }
}

struct InspectorTabBar: View {
    @Binding var selectedTab: InspectorTab

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(InspectorTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.rawValue, systemImage: tab.icon)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .foregroundStyle(selectedTab == tab ? Color.white : Color.primary)
                            .background(
                                selectedTab == tab ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(tab.rawValue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

struct GitInspectorView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .frame(width: 28, height: 28)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 5) {
                    Text(appState.gitStatus.branch ?? "No branch")
                        .font(.headline)
                        .lineLimit(1)
                    Text(appState.gitStatus.cwd ?? "No working directory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            VSplitView {
                GitFilesPane()
                    .frame(minHeight: 110, idealHeight: 240, maxHeight: .infinity)

                GitDiffPane()
                    .frame(minHeight: 220, idealHeight: 460, maxHeight: .infinity)
            }
        }
    }
}

struct GitFilesPane: View {
    @EnvironmentObject private var appState: MacHarnessAppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let staged = appState.gitStatus.staged ?? []
                let unstaged = appState.gitStatus.unstaged ?? []
                let untracked = appState.gitStatus.untracked ?? []
                if staged.isEmpty && unstaged.isEmpty && untracked.isEmpty {
                    ContentUnavailableView("Clean", systemImage: "checkmark.circle", description: Text("No working tree changes."))
                        .frame(maxWidth: .infinity, minHeight: 120)
                }

                GitFileSection(title: "Staged", files: staged, section: "staged", isStaged: true)
                GitFileSection(title: "Unstaged", files: unstaged, section: "unstaged", isStaged: false)
                if !untracked.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Untracked")
                                .font(.subheadline.weight(.semibold))
                            CountBadge(value: untracked.count)
                            Spacer()
                        }
                        ForEach(untracked, id: \.self) { file in
                            GitFileRowView(
                                file: file,
                                status: "?",
                                section: "untracked",
                                isStaged: false,
                                canStage: true
                            )
                        }
                    }
                }

                if let commits = appState.gitStatus.commits, !commits.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Recent Commits")
                                .font(.subheadline.weight(.semibold))
                            CountBadge(value: commits.count)
                            Spacer()
                        }
                        ForEach(commits) { commit in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(commit.message)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(2)
                                Text(commit.hash)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

struct GitDiffPane: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(appState.selectedGitFile ?? "Diff")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if appState.selectedGitFile != nil {
                    MetadataChip(text: appState.selectedGitSection, color: .secondary)
                }
                Spacer()
                Button {
                    Task { await appState.openSelectedGitFile(supervisor: supervisor) }
                } label: {
                    Label("Open File", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .disabled(appState.selectedGitFile == nil || appState.mode == .localDemo)
            }

            DiffViewer(
                diffText: appState.diffText,
                isLoading: appState.isLoadingDiff,
                error: appState.diffError
            )
        }
        .padding(14)
    }
}

struct DiffViewer: View {
    var diffText: String
    var isLoading: Bool = false
    var error: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading diff...")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else if let error {
                ContentUnavailableView("Diff Failed", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(minHeight: 220)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(parsedLines) { line in
                            DiffLineView(line: line)
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(minWidth: 560, alignment: .leading)
                }
            }
        }
        .frame(minHeight: 180, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
    }

    private var parsedLines: [MacDiffLine] {
        parseMacDiffLines(diffText.isEmpty ? "No diff selected." : diffText)
    }
}

struct DiffLineView: View {
    var line: MacDiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldLine.map(String.init) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary.opacity(0.75))
                .frame(width: 38, alignment: .trailing)
                .padding(.trailing, 8)
            Text(line.newLine.map(String.init) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary.opacity(0.75))
                .frame(width: 38, alignment: .trailing)
                .padding(.trailing, 8)
            Text(line.marker)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(foreground)
                .frame(width: 18, alignment: .center)
            Text(line.displayText.isEmpty ? " " : line.displayText)
                .font(.caption.monospaced())
                .foregroundStyle(foreground)
                .textSelection(.enabled)
                .padding(.leading, 6)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
            .padding(.vertical, 1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
    }

    private var foreground: Color {
        switch line.kind {
        case .addition:
            return .green
        case .deletion:
            return .red
        case .hunk:
            return .purple
        case .metadata:
            return .secondary
        case .context:
            return Color(nsColor: .labelColor)
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition:
            return Color.green.opacity(0.10)
        case .deletion:
            return Color.red.opacity(0.10)
        case .hunk:
            return Color.purple.opacity(0.10)
        default:
            return .clear
        }
    }
}

enum MacDiffLineKind {
    case metadata
    case hunk
    case context
    case addition
    case deletion
}

struct MacDiffLine: Identifiable {
    var id: Int
    var raw: String
    var kind: MacDiffLineKind
    var oldLine: Int?
    var newLine: Int?

    var marker: String {
        switch kind {
        case .addition:
            "+"
        case .deletion:
            "-"
        case .context:
            " "
        case .metadata, .hunk:
            ""
        }
    }

    var displayText: String {
        switch kind {
        case .addition, .deletion, .context:
            raw.isEmpty ? "" : String(raw.dropFirst())
        case .metadata, .hunk:
            raw
        }
    }
}

private func parseMacDiffLines(_ diff: String) -> [MacDiffLine] {
    var oldLine: Int?
    var newLine: Int?
    return diff.components(separatedBy: .newlines).enumerated().map { offset, raw in
        if raw.hasPrefix("@@") {
            let parsed = parseDiffHunkHeader(raw)
            oldLine = parsed.old
            newLine = parsed.new
            return MacDiffLine(id: offset, raw: raw, kind: .hunk, oldLine: nil, newLine: nil)
        }
        if raw.hasPrefix("+"), !raw.hasPrefix("+++") {
            let line = MacDiffLine(id: offset, raw: raw, kind: .addition, oldLine: nil, newLine: newLine)
            newLine = newLine.map { $0 + 1 }
            return line
        }
        if raw.hasPrefix("-"), !raw.hasPrefix("---") {
            let line = MacDiffLine(id: offset, raw: raw, kind: .deletion, oldLine: oldLine, newLine: nil)
            oldLine = oldLine.map { $0 + 1 }
            return line
        }
        if raw.hasPrefix(" ") {
            let line = MacDiffLine(id: offset, raw: raw, kind: .context, oldLine: oldLine, newLine: newLine)
            oldLine = oldLine.map { $0 + 1 }
            newLine = newLine.map { $0 + 1 }
            return line
        }
        return MacDiffLine(id: offset, raw: raw, kind: .metadata, oldLine: nil, newLine: nil)
    }
}

private func parseDiffHunkHeader(_ line: String) -> (old: Int?, new: Int?) {
    let parts = line.split(separator: " ")
    let oldPart = parts.first { $0.hasPrefix("-") }
    let newPart = parts.first { $0.hasPrefix("+") }
    return (parseDiffLineStart(oldPart), parseDiffLineStart(newPart))
}

private func parseDiffLineStart(_ part: Substring?) -> Int? {
    guard let part else { return nil }
    let trimmed = part.dropFirst().split(separator: ",").first ?? ""
    return Int(trimmed)
}

struct GitFileSection: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor
    var title: String
    var files: [GitFile]
    var section: String
    var isStaged: Bool

    var body: some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    CountBadge(value: files.count)
                    Spacer()
                }
                ForEach(files) { file in
                    GitFileRowView(
                        file: file.file,
                        status: file.status,
                        section: section,
                        isStaged: isStaged,
                        canStage: true
                    )
                }
            }
        }
    }
}

struct GitFileRowView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor
    var file: String
    var status: String
    var section: String
    var isStaged: Bool
    var canStage: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(status)
                .font(.caption.monospaced())
                .foregroundStyle(statusColor)
                .frame(width: 24, alignment: .leading)
            Text(file)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if canStage {
                Button {
                    Task {
                        if isStaged {
                            await appState.unstageFile(file, supervisor: supervisor)
                        } else {
                            await appState.stageFile(file, supervisor: supervisor)
                        }
                    }
                } label: {
                    Image(systemName: isStaged ? "minus.circle" : "plus.circle")
                }
                .buttonStyle(.borderless)
                .help(isStaged ? "Unstage" : "Stage")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture {
            Task { await appState.loadDiff(file: file, section: section, supervisor: supervisor) }
        }
    }

    private var isSelected: Bool {
        appState.selectedGitFile == file && appState.selectedGitSection == section
    }

    private var statusColor: Color {
        if section == "staged" { return .green }
        if section == "untracked" { return .secondary }
        return .orange
    }

    private var rowBackground: Color {
        isSelected
            ? Color.accentColor.opacity(0.18)
            : Color(nsColor: .controlBackgroundColor).opacity(0.55)
    }
}

struct PRCommentsView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor

    var body: some View {
        List {
            Section {
                Toggle("Show resolved", isOn: $appState.includeResolvedPRComments)
                    .onChange(of: appState.includeResolvedPRComments) {
                        Task { await appState.refreshTools(supervisor: supervisor) }
                    }
                Button {
                    Task { await appState.refreshTools(supervisor: supervisor) }
                } label: {
                    Label("Refresh PR Comments", systemImage: "arrow.clockwise")
                }
            }

            if appState.prThreads.isEmpty {
                ContentUnavailableView("No PR Comments", systemImage: "text.bubble", description: Text("No review threads were found for this branch."))
            } else {
                ForEach(groupedThreads, id: \.path) { group in
                    Section(group.path) {
                        ForEach(group.threads) { thread in
                            PRThreadCard(thread: thread)
                        }
                    }
                }
            }
        }
    }

    private var groupedThreads: [(path: String, threads: [GitHubPRThread])] {
        Dictionary(grouping: appState.prThreads) { $0.path ?? "Unknown file" }
            .map { path, threads in
                (path, threads.sorted { ($0.line ?? 0) < ($1.line ?? 0) })
            }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }
}

struct PRThreadCard: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    var thread: GitHubPRThread

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Label(lineLabel, systemImage: "number")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                if thread.isResolved == true {
                    MetadataChip(text: "Resolved", color: .green)
                }
                if thread.isOutdated == true {
                    MetadataChip(text: "Outdated", color: .orange)
                }
                Spacer(minLength: 8)
                Button {
                    insertReference()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Insert PR comment context")

                Button {
                    copyReference()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy PR comment context")

                Button {
                    openThread()
                } label: {
                    Image(systemName: "link")
                }
                .buttonStyle(.borderless)
                .disabled((thread.url ?? "").isEmpty)
                .help("Open PR comment")
            }

            ForEach(thread.comments ?? []) { comment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(comment.author ?? "reviewer")
                            .font(.caption.weight(.bold))
                        if let createdAt = comment.createdAt, !createdAt.isEmpty {
                            Text(createdAt)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(comment.bodyText ?? "")
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            Button {
                requestFix()
            } label: {
                Label("Request Fix", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 6)
    }

    private var lineLabel: String {
        thread.line.map { "Line \($0)" } ?? "File"
    }

    private var referenceText: String {
        let comments = (thread.comments ?? [])
            .map { "\($0.author ?? "reviewer"): \($0.bodyText ?? "")" }
            .joined(separator: "\n")
        return "PR comment in \(thread.path ?? "this file") \(lineLabel)\n\(comments)"
    }

    private func insertReference() {
        appState.draft += "\n\(referenceText)"
    }

    private func requestFix() {
        appState.draft += "\nFix this \(referenceText)"
    }

    private func copyReference() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(referenceText, forType: .string)
    }

    private func openThread() {
        guard let urlString = thread.url, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct JiraView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor
    @State private var copiedTicketKey: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Lookup Jira issue or URL", text: $appState.jiraLookupQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await appState.lookupJira(supervisor: supervisor) }
                    }
                Button {
                    Task { await appState.lookupJira(supervisor: supervisor) }
                } label: {
                    Label("Lookup", systemImage: "magnifyingglass")
                }
                .disabled(appState.jiraLookupQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    Task { await appState.refreshTools(supervisor: supervisor) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh assigned tickets")
            }
            .padding(12)

            if let ticket = appState.resolvedJiraTicket {
                JiraTicketCard(ticket: ticket, copiedTicketKey: $copiedTicketKey)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else if let error = appState.jiraLookupError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Divider()

            List {
                if appState.jiraTickets.isEmpty {
                    ContentUnavailableView("No Assigned Tickets", systemImage: "ticket")
                } else {
                    ForEach(groupedTickets, id: \.project) { group in
                        Section(group.project) {
                            ForEach(group.tickets) { ticket in
                                JiraTicketCard(ticket: ticket, copiedTicketKey: $copiedTicketKey)
                            }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if let copiedTicketKey {
                Label("Copied \(copiedTicketKey)", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
    }

    private var groupedTickets: [(project: String, tickets: [JiraTicket])] {
        let groups = Dictionary(grouping: appState.jiraTickets) { ticket in
            projectKey(for: ticket)
        }
        let mapped = groups.map { project, tickets in
            let sortedTickets = tickets.sorted {
                $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
            return (project: project, tickets: sortedTickets)
        }
        return mapped.sorted {
            $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending
        }
    }

    private func projectKey(for ticket: JiraTicket) -> String {
        ticket.key.split(separator: "-", maxSplits: 1).first.map(String.init) ?? "Other"
    }
}

struct JiraTicketCard: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    var ticket: JiraTicket
    @Binding var copiedTicketKey: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    copyKey()
                } label: {
                    Text(ticket.key)
                        .font(.callout.monospaced().weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Copy Jira key")

                Text(ticket.summary ?? "No summary")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)

                Label((ticket.status ?? "Unknown").isEmpty ? "Unknown" : (ticket.status ?? "Unknown"), systemImage: "circle.dotted")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            Spacer(minLength: 8)

            VStack(spacing: 10) {
                Button {
                    openTicket()
                } label: {
                    Image(systemName: "link")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled((ticket.url ?? "").isEmpty)
                .help("Open Jira ticket")

                Button {
                    insertReference()
                } label: {
                    Image(systemName: "text.badge.plus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Insert Jira ticket context")
            }
        }
        .padding(.vertical, 6)
    }

    private func insertReference() {
        appState.draft += "\nUse Jira \(ticket.key): \(ticket.summary ?? "")"
    }

    private func copyKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ticket.key, forType: .string)
        withAnimation(.easeInOut(duration: 0.18)) {
            copiedTicketKey = ticket.key
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            withAnimation(.easeInOut(duration: 0.18)) {
                if copiedTicketKey == ticket.key {
                    copiedTicketKey = nil
                }
            }
        }
    }

    private func openTicket() {
        guard let urlString = ticket.url, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct FilesInspectorView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search files", text: $appState.fileSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await appState.refreshTools(supervisor: supervisor) }
                    }
                Button {
                    Task { await appState.refreshTools(supervisor: supervisor) }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
            .padding(12)

            List {
                if appState.fileSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 {
                    ContentUnavailableView("Search Files", systemImage: "at", description: Text("Type at least three characters to search project files."))
                } else if appState.fileMatches.isEmpty {
                    ContentUnavailableView("No Matches", systemImage: "doc.text.magnifyingglass")
                } else {
                    ForEach(appState.fileMatches) { match in
                        Button {
                            appState.draft += "\n@\(match.path)"
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(match.path)
                                        .font(.callout.monospaced())
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                    if let preview = match.preview {
                                        Text(preview)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct SkillsInspectorView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Skills")
                        .font(.headline)
                    Text("Insert a Claude Code skill invocation or attach its file path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await appState.refreshTools(supervisor: supervisor) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding(12)

            List {
                if appState.projectSkills.isEmpty && appState.userSkills.isEmpty {
                    ContentUnavailableView("No Skills", systemImage: "wand.and.stars")
                }
                if !appState.projectSkills.isEmpty {
                    Section("Project Skills") {
                        ForEach(appState.projectSkills) { skill in
                            SkillMenuRow(skill: skill)
                        }
                    }
                }
                if !appState.userSkills.isEmpty {
                    Section("User Skills") {
                        ForEach(appState.userSkills) { skill in
                            SkillMenuRow(skill: skill)
                        }
                    }
                }
            }
        }
    }
}

struct SkillMenuRow: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    var skill: ProjectSkill

    var body: some View {
        Menu {
            Button {
                appState.draft += "\n$\(skill.name)"
            } label: {
                Label("Claude Code", systemImage: "terminal")
            }
            if let path = skill.path, !path.isEmpty {
                Button {
                    appState.draft += "\n@\(path)"
                } label: {
                    Label("File Path", systemImage: "doc.text")
                }
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                        .font(.subheadline.weight(.semibold))
                    Text(skill.description ?? skill.path ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let path = skill.path, !path.isEmpty {
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .buttonStyle(.plain)
    }
}

struct AttachmentsView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor
    @State private var isImporterPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Attachments")
                        .font(.headline)
                    Text("Upload files to the selected cmux workspace and insert references into the prompt draft.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Add File", systemImage: "paperclip")
                }
            }
            .padding(12)

            Divider()

            let workspaceID = appState.selectedWorkspace?.id ?? ""
            let items = appState.attachments[workspaceID] ?? []
            List {
                if items.isEmpty {
                    ContentUnavailableView("No Attachments", systemImage: "paperclip", description: Text("Add a file to upload it to the selected session."))
                }
                ForEach(items) { attachment in
                    HStack {
                        Image(systemName: systemImage(for: attachment))
                            .foregroundStyle(iconColor(for: attachment))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(attachment.filename)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(statusText(for: attachment))
                                .font(.caption)
                                .foregroundStyle(statusColor(for: attachment))
                                .lineLimit(1)
                        }
                        Spacer()
                        if case .uploading = attachment.state {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if case .failed = attachment.state {
                            Button {
                                Task { await appState.retryAttachment(workspaceID: workspaceID, attachmentID: attachment.id, supervisor: supervisor) }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .help("Retry upload")
                            .accessibilityLabel("Retry attachment upload")
                        }
                        Button {
                            appState.removeAttachment(workspaceID: workspaceID, attachmentID: attachment.id)
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove attachment")
                        .accessibilityLabel("Remove attachment")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task { await appState.addAttachment(url, supervisor: supervisor) }
        }
    }

    private func systemImage(for attachment: TerminalAttachment) -> String {
        let ext = attachment.filename.split(separator: ".").last.map { String($0).lowercased() } ?? ""
        if ["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(ext) {
            return "photo"
        }
        if ["m4a", "mp3", "wav", "aac", "caf"].contains(ext) {
            return "waveform"
        }
        if ext == "pdf" {
            return "doc.richtext"
        }
        if ["zip", "gz", "tar"].contains(ext) {
            return "archivebox"
        }
        return "doc"
    }

    private func iconColor(for attachment: TerminalAttachment) -> Color {
        switch attachment.state {
        case .uploaded:
            .green
        case .failed:
            .orange
        case .uploading:
            .accentColor
        default:
            .secondary
        }
    }

    private func statusText(for attachment: TerminalAttachment) -> String {
        if case let .failed(message) = attachment.state {
            return message
        }
        return attachment.state.label
    }

    private func statusColor(for attachment: TerminalAttachment) -> Color {
        switch attachment.state {
        case .uploaded:
            .green
        case .failed:
            .orange
        default:
            .secondary
        }
    }
}

struct ActivityInspectorView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Activity")
                        .font(.headline)
                    Text("Recent harness actions for the selected server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await appState.refresh(supervisor: supervisor) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding(12)

            Divider()

            List {
                if appState.logEntries.isEmpty {
                    ContentUnavailableView("No Activity", systemImage: "list.bullet.rectangle")
                } else {
                    ForEach(appState.logEntries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.action ?? "Activity")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                if let timestamp = entry.timestamp, !timestamp.isEmpty {
                                    Text(timestamp)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            if let promptType = entry.promptType, !promptType.isEmpty {
                                MetadataChip(text: promptType, color: .secondary)
                            }
                            Text([entry.workspaceName, entry.reason].compactMap { $0 }.joined(separator: " • "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

struct LogView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor

    var body: some View {
        HSplitView {
            List(appState.logEntries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.action ?? "event")
                        .font(.subheadline.weight(.semibold))
                    Text([entry.workspaceName, entry.reason].compactMap { $0 }.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Server Output")
                    .font(.headline)
                ScrollView {
                    Text(supervisor.recentOutput.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: MacHarnessAppState
    @EnvironmentObject private var supervisor: ServerSupervisor
    @AppStorage("cmuxHarnessMacServerPort") private var serverPort = 9091
    @AppStorage("cmuxHarnessMacLaunchServerAtAppStart") private var launchServerAtAppStart = true
    @AppStorage("cmuxHarnessMacKeepServerRunningAfterWindowClose") private var keepServerRunningAfterWindowClose = false
    @AppStorage("cmuxHarnessMacAutoRestartServer") private var autoRestartServer = true

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Mode", value: appState.mode.rawValue)
                LabeledContent("Phase", value: supervisor.phase.label)
                LabeledContent("URL", value: supervisor.baseURLString)
                Stepper("Server Port: \(serverPort)", value: $serverPort, in: 1024...65_535)
                Toggle("Launch server at app start", isOn: $launchServerAtAppStart)
                Toggle("Keep server running after closing window", isOn: $keepServerRunningAfterWindowClose)
                Toggle("Restart server after crash", isOn: Binding(
                    get: { supervisor.autoRestart },
                    set: { value in
                        autoRestartServer = value
                        supervisor.autoRestart = value
                    }
                ))
                HStack {
                    Button("Start") { supervisor.start(port: serverPort) }
                    Button("Stop") { supervisor.stop() }
                    Button("Restart") { supervisor.restart(port: serverPort) }
                    Button("Open Browser Dashboard") { supervisor.openBrowserDashboard() }
                    Button("Open cmux") { supervisor.openCmux() }
                }
            }

            Section("cmux") {
                LabeledContent("Socket", value: appState.status.socketFound == true ? "Found" : "Missing")
                LabeledContent("Connection", value: appState.status.connected == true ? "Connected" : "Waiting")
                LabeledContent("Workspace Count", value: "\(appState.workspaces.count)")
            }

            Section("Network") {
                LabeledContent("iPhone URL", value: supervisor.network?.urls?.lanHarness?.first ?? supervisor.baseURLString)
                TextField("Tailscale host or IP", text: $appState.tailscaleHostString)
                Button("Try Tailscale Host/IP") {
                    Task { await appState.tryTailscaleHost(supervisor: supervisor) }
                }
                Button("Copy iPhone URL") { supervisor.copyIPhoneURL() }
            }

            Section("CLI Diagnostics") {
                LabeledContent("GitHub CLI", value: commandAvailability("gh"))
                LabeledContent("Atlassian CLI", value: [commandAvailability("acli"), commandAvailability("jira")].contains("Found") ? "Found" : "Missing")
            }

            Section("Review") {
                LabeledContent("Enabled", value: appState.status.reviewEnabled == true ? "Yes" : "No")
                LabeledContent("Model", value: appState.status.reviewModel ?? "Unset")
                LabeledContent("Backend", value: appState.status.reviewBackend ?? "Unset")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func commandAvailability(_ command: String) -> String {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for path in paths {
            let candidate = URL(fileURLWithPath: String(path)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return "Found"
            }
        }
        return "Missing"
    }
}
