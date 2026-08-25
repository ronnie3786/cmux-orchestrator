import { useEffect, useState } from "react";
import { Menu } from "lucide-react";
import {
  configureClient,
  getToken,
  setDemoRequestHandler,
  setServerUrl,
  setToken,
} from "./api/client";
import { useConnectionStore } from "./store/connectionStore";
import { useEventStreamStore } from "./store/eventStream";
import { useWorkspacesStore } from "./store/workspacesStore";
import {
  embeddedGitRoute,
  getHashRoute,
  parseHash,
  setHashRoute,
  subscribeHash,
} from "./lib/hashRoute";
import { Sidebar } from "./components/Sidebar/Sidebar";
import { WorkspaceListView } from "./components/Workspace/WorkspaceListView";
import { DetailPlaceholder } from "./components/Detail/DetailPlaceholder";
import { AttentionView } from "./components/Attention/AttentionView";
import { TerminalView } from "./components/Terminal/TerminalView";
import { GitStatusView } from "./components/Git/GitStatusView";
import { SkillsView } from "./components/Skills/SkillsView";
import { PiChatPane } from "./components/Pi/PiChatView";
import { Toast } from "./components/Toast/Toast";
import { ConnectionIssue } from "./components/Shared/ConnectionIssue";
import { OnboardingView } from "./components/Onboarding/OnboardingView";
import { SettingsModal } from "./components/Settings/SettingsModal";
import { disableDemoMode, demoEnabled, demoRequest, enableDemoMode } from "./demo/demoAdapter";
import { useWorkspaceHashRoute } from "./hooks/useWorkspaceHashRoute";
import { usePaneModeStore } from "./store/paneModeStore";
import { usePaneViewStore } from "./store/paneViewStore";
import "./styles/app.css";

/**
 * App shell: onboarding (no token, no demo) → 3-region layout — the "chats"
 * navigator rail | the workspace list | the detail. Demo mode (no token
 * needed) renders the same shell fed by the demo adapter; the "Demo data is
 * active" banner sits in the workspace list header.
 *
 * With a token the app probes /health, arms the /workspaces refresh, and
 * opens the global SSE stream; the shell renders once the probe settles
 * (any 401 re-enters onboarding via the client's onUnauthorized hook).
 * Selection is driven by the `#ws=<id>&pane=<id>` hash route; the `deck=1`
 * param swaps the right region from the detail placeholder to the
 * Attention Deck (P3-run-B).
 */
export default function App() {
  const embeddedGit = embeddedGitRoute(window.location.hash);
  if (embeddedGit !== null) {
    return (
      <>
        <GitStatusView paneId={embeddedGit.paneId} embedded />
        <Toast />
      </>
    );
  }
  return <HerdrShell />;
}

function HerdrShell() {
  const [token, setStoredToken] = useState<string>(() => getToken());
  const [probed, setProbed] = useState(false);
  // Responsive drawers: the "chats" navigator rail becomes a drawer below
  // 1100 px; the workspace list becomes one too below 700 px (phone).
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [wsDrawerOpen, setWsDrawerOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  // Bumped by Settings "Save and reconnect" to re-run the probe/SSE effect
  // against the new server URL (the token is kept — a 401 re-enters
  // onboarding via onUnauthorized).
  const [serverGeneration, setServerGeneration] = useState(0);

  const demo = useConnectionStore((state) => state.demo);

  const selectedWorkspaceId = useWorkspacesStore((state) => state.selectedWorkspaceId);
  const selectedPaneId = useWorkspacesStore((state) => state.selectedPaneId);
  const data = useWorkspacesStore((state) => state.data);

  // Pi pane mode override ("chat" | "terminal", pane ⋯ menu). This hook MUST
  // run unconditionally — before the early returns below — or the hook order
  // changes once the token is entered and React throws #310.
  const selectedWorkspace =
    data?.workspaces.find((candidate) => candidate.workspace_id === selectedWorkspaceId) ?? null;
  const selectedPane =
    selectedWorkspace?.panes.find((candidate) => candidate.pane_id === selectedPaneId) ?? null;
  const paneMode = usePaneModeStore((state) =>
    selectedPane !== null ? state.modeFor(selectedPane) : null,
  );
  const paneView = usePaneViewStore((state) =>
    selectedPane !== null ? state.viewFor(selectedPane) : null,
  );

  const clearToken = () => {
    setToken("");
    useEventStreamStore.getState().stop();
    useWorkspacesStore.setState({
      data: null,
      lastUpdated: null,
      refreshing: false,
      selectedWorkspaceId: null,
      selectedPaneId: null,
    });
    useConnectionStore.setState({
      status: "Offline",
      streamOpen: false,
      herdr: null,
      herdrEventsConnected: null,
      lastProbeAt: null,
      demo: false,
    });
    setStoredToken("");
    setProbed(false);
    setSidebarOpen(false);
    setWsDrawerOpen(false);
  };

  // Any 401 from the API re-enters onboarding (client contract); the demo
  // adapter is installed for the whole session.
  useEffect(() => {
    configureClient({ onUnauthorized: clearToken });
    setDemoRequestHandler(demoRequest);
    // Stable setters + module stores — register once.
  }, []);

  // Mount with a token: probe /health, refresh the snapshot, open SSE.
  // `serverGeneration` re-runs this after a Settings "Save and reconnect".
  useEffect(() => {
    if (!token) return;
    setProbed(false);
    void useConnectionStore
      .getState()
      .probe()
      .then(() => setProbed(true));
    void useWorkspacesStore.getState().refresh();
    useEventStreamStore.getState().start(token);
    return () => {
      useEventStreamStore.getState().stop();
    };
  }, [token, serverGeneration]);

  useWorkspaceHashRoute(token);

  // Attention deck (P3-run-B): `deck=1` in the hash opens the deck in the
  // right region. Anchor navigation (#deck=1 from the attention strip, alert
  // deep links) arrives via hashchange; the back button clears the param via
  // replaceState and updates the state directly (replaceState fires no event).
  const [deckOpen, setDeckOpen] = useState<boolean>(
    () => parseHash(window.location.hash).params.deck === "1",
  );
  useEffect(
    () =>
      subscribeHash(() => setDeckOpen(parseHash(window.location.hash).params.deck === "1")),
    [],
  );
  const closeDeck = () => {
    const route = getHashRoute();
    const params = { ...route.params };
    delete params.deck;
    setHashRoute({ ...route, params });
    setDeckOpen(false);
  };

  // Selecting something closes the responsive drawers (Phase-1 pattern).
  useEffect(() => {
    setSidebarOpen(false);
    setWsDrawerOpen(false);
  }, [selectedWorkspaceId, selectedPaneId]);

  const saveToken = (serverUrl: string, value: string) => {
    setServerUrl(serverUrl);
    setToken(value);
    useConnectionStore.getState().setToken(value);
    setStoredToken(value);
  };

  // Settings "Save and reconnect" / "Connect a real server": persist the
  // URL, leave demo mode if active, and re-probe + reopen the stream.
  // Without a token this drops back into onboarding (demo off, no token).
  const reconnect = (serverUrl: string) => {
    if (demoEnabled()) {
      disableDemoMode();
    }
    setServerUrl(serverUrl);
    setSettingsOpen(false);
    setServerGeneration((generation) => generation + 1);
  };

  const exploreDemo = () => {
    enableDemoMode();
  };

  if (!demo && !token) {
    return (
      <OnboardingView onConnect={saveToken} onExploreDemo={exploreDemo} />
    );
  }

  if (!demo && !probed) {
    return (
      <main className="screen">
        <section className="card">
          <h1>herdr</h1>
          <p className="hint">Connecting</p>
        </section>
      </main>
    );
  }

  const workspace = selectedWorkspace;
  // Pi capability gate (doc 01 §4.4): available && protocol version 1.
  const supportsPiChat =
    selectedPane?.pi_semantic !== undefined &&
    selectedPane.pi_semantic.available &&
    selectedPane.pi_semantic.protocol_version === 1;
  // Pi panes default to Chat; a stored "terminal" override (pane ⋯ menu) wins.
  const showPiChat = supportsPiChat && paneMode !== "terminal";
  // Non-Pi panes default to Terminal; the ⋯ menu "View" section overrides.
  const effectiveView = paneView ?? "terminal";

  return (
    <div className="hz-app-shell">
      <Sidebar
        open={sidebarOpen}
        onClose={() => setSidebarOpen(false)}
        onOpenSettings={() => setSettingsOpen(true)}
      />
      <WorkspaceListView
        onOpenNavigator={() => setSidebarOpen(true)}
        drawerOpen={wsDrawerOpen}
        onCloseDrawer={() => setWsDrawerOpen(false)}
      />
      {/* Phone top bar (visible <700 px only): both drawer triggers live in
          the detail region's header area, since the workspace list itself is
          a drawer at this width. */}
      <div className="hz-phone-topbar">
        <button
          type="button"
          className="hz-nav-toggle"
          onClick={() => setSidebarOpen(true)}
          aria-label="Open navigator"
        >
          <Menu size={16} aria-hidden />
        </button>
        <button
          type="button"
          className="hz-phone-topbar-workspaces"
          onClick={() => setWsDrawerOpen(true)}
        >
          workspaces
        </button>
      </div>
      {wsDrawerOpen ? (
        <div className="hz-ws-drawer-backdrop" onClick={() => setWsDrawerOpen(false)} aria-hidden />
      ) : null}
      {deckOpen ? (
        <AttentionView onClose={closeDeck} />
      ) : selectedPaneId !== null ? (
        showPiChat ? (
          <PiChatPane />
        ) : effectiveView === "git" ? (
          <GitStatusView paneId={selectedPaneId} />
        ) : effectiveView === "skills" ? (
          <SkillsView />
        ) : (
          <TerminalView />
        )
      ) : (
        <DetailPlaceholder workspace={workspace} />
      )}
      {settingsOpen ? (
        <SettingsModal onClose={() => setSettingsOpen(false)} onReconnect={reconnect} />
      ) : null}
      <ConnectionIssue />
      <Toast />
    </div>
  );
}
