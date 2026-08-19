import { useEffect, useState } from "react";
import { configureClient, getToken, setToken } from "./api/client";
import { useConnectionStore } from "./store/connectionStore";
import { useEventStreamStore } from "./store/eventStream";
import { useWorkspacesStore } from "./store/workspacesStore";
import { Sidebar } from "./components/Sidebar/Sidebar";
import { WorkspaceListView } from "./components/Workspace/WorkspaceListView";
import { DetailPlaceholder } from "./components/Detail/DetailPlaceholder";
import { Toast } from "./components/Toast/Toast";
import { useWorkspaceHashRoute } from "./hooks/useWorkspaceHashRoute";
import "./styles/app.css";

/**
 * App shell (P3-run-A): token gate → 3-region layout — the "chats"
 * navigator rail | the workspace list | the detail placeholder.
 *
 * With a token the app probes /health, arms the /workspaces refresh, and
 * opens the global SSE stream; the shell renders once the probe settles
 * (any 401 re-enters the token form via the client's onUnauthorized hook).
 * Selection is driven by the `#ws=<id>&pane=<id>` hash route.
 */
export default function App() {
  const [token, setStoredToken] = useState<string>(() => getToken());
  const [draft, setDraft] = useState("");
  const [probed, setProbed] = useState(false);
  // Responsive "chats" drawer (visible only below the 900 px breakpoint).
  const [sidebarOpen, setSidebarOpen] = useState(false);

  const selectedWorkspaceId = useWorkspacesStore((state) => state.selectedWorkspaceId);
  const data = useWorkspacesStore((state) => state.data);

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

  const workspace =
    data?.workspaces.find((candidate) => candidate.workspace_id === selectedWorkspaceId) ?? null;

  return (
    <div className="hz-app-shell">
      <Sidebar open={sidebarOpen} onClose={() => setSidebarOpen(false)} />
      <WorkspaceListView onOpenNavigator={() => setSidebarOpen(true)} />
      <DetailPlaceholder workspace={workspace} />
      <Toast />
    </div>
  );
}
