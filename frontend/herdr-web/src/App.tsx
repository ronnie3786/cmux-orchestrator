import { useEffect, useState } from "react";
import { configureClient, getToken, setToken } from "./api/client";
import { useConnectionStore } from "./store/connectionStore";
import { useEventStreamStore } from "./store/eventStream";
import { useWorkspacesStore } from "./store/workspacesStore";
import { getHashRoute, parseHash, setHashRoute, subscribeHash } from "./lib/hashRoute";
import { Sidebar } from "./components/Sidebar/Sidebar";
import { WorkspaceListView } from "./components/Workspace/WorkspaceListView";
import { DetailPlaceholder } from "./components/Detail/DetailPlaceholder";
import { AttentionView } from "./components/Attention/AttentionView";
import { TerminalView } from "./components/Terminal/TerminalView";
import { GitStatusView } from "./components/Git/GitStatusView";
import { SkillsView } from "./components/Skills/SkillsView";
import { PiChatPane } from "./components/Pi/PiChatView";
import { Toast } from "./components/Toast/Toast";
import { useWorkspaceHashRoute } from "./hooks/useWorkspaceHashRoute";
import { usePaneModeStore } from "./store/paneModeStore";
import { usePaneViewStore } from "./store/paneViewStore";
import "./styles/app.css";

/**
 * App shell (P3-run-A): token gate → 3-region layout — the "chats"
 * navigator rail | the workspace list | the detail placeholder.
 *
 * With a token the app probes /health, arms the /workspaces refresh, and
 * opens the global SSE stream; the shell renders once the probe settles
 * (any 401 re-enters the token form via the client's onUnauthorized hook).
 * Selection is driven by the `#ws=<id>&pane=<id>` hash route; the `deck=1`
 * param swaps the right region from the detail placeholder to the
 * Attention Deck (P3-run-B).
 */
export default function App() {
  const [token, setStoredToken] = useState<string>(() => getToken());
  const [draft, setDraft] = useState("");
  const [probed, setProbed] = useState(false);
  // Responsive "chats" drawer (visible only below the 900 px breakpoint).
  const [sidebarOpen, setSidebarOpen] = useState(false);

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
  };

  // Any 401 from the API re-enters the token form (client contract).
  useEffect(() => {
    configureClient({ onUnauthorized: clearToken });
    // Stable setters + module stores — register once.
  }, []);

  // Mount with a token: probe /health, refresh the snapshot, open SSE.
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
  }, [token]);

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

  // Selecting something closes the responsive drawer (Phase-1 pattern).
  useEffect(() => {
    setSidebarOpen(false);
  }, [selectedWorkspaceId]);

  const saveToken = () => {
    const value = draft.trim();
    if (!value) return;
    setToken(value);
    useConnectionStore.getState().setToken(value);
    setStoredToken(value);
    setDraft("");
  };

  if (!token) {
    return (
      <main className="screen">
        <section className="card">
          <h1>herdr</h1>
          <p className="hint">Enter the pairing token printed in the herdr harness log.</p>
          <form
            onSubmit={(event) => {
              event.preventDefault();
              saveToken();
            }}
          >
            <label htmlFor="pairing-token" className="hint">
              Pairing token
            </label>
            <input
              id="pairing-token"
              type="password"
              className="token-input"
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              placeholder="Token from server log"
              autoFocus
              autoComplete="off"
              spellCheck={false}
            />
            <button type="submit" className="primary" disabled={!draft.trim()}>
              Connect
            </button>
          </form>
        </section>
      </main>
    );
  }

  if (!probed) {
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
      <Sidebar open={sidebarOpen} onClose={() => setSidebarOpen(false)} />
      <WorkspaceListView onOpenNavigator={() => setSidebarOpen(true)} />
      {deckOpen ? (
        <AttentionView onClose={closeDeck} />
      ) : selectedPaneId !== null ? (
        showPiChat ? (
          <PiChatPane />
        ) : effectiveView === "git" ? (
          <GitStatusView />
        ) : effectiveView === "skills" ? (
          <SkillsView />
        ) : (
          <TerminalView />
        )
      ) : (
        <DetailPlaceholder workspace={workspace} />
      )}
      <Toast />
    </div>
  );
}
