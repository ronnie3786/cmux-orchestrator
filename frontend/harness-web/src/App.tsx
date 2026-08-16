import { useEffect, useRef, useState } from "react";
import { KeyRound } from "lucide-react";
import { getToken, setToken } from "./api/client";
import { getFeed, getLog, getNotifications, getOpenCodeIntegration, getStatus } from "./api/endpoints";
import { ConnectionBar } from "./components/ConnectionBar";
import { Sidebar } from "./components/Sidebar";
import { NewSessionModal } from "./components/Sessions/NewSessionModal";
import { SessionCreationProgressOverlay } from "./components/Sessions/SessionCreationProgressOverlay";
import { SettingsModal } from "./components/Settings/SettingsModal";
import { WorkspaceDetailView } from "./components/Workspace/WorkspaceDetailView";
import { useConnectionStore } from "./store/connectionStore";
import { useNewSessionStore } from "./store/newSessionStore";
import { useSessionStore } from "./store/sessionStore";
import { useWorkspacesStore } from "./store/workspacesStore";
import { groups, sessionGroupID, workspaceID } from "./lib/workspaceGroups";

const POLL_INTERVAL_MS = 2_000;

export default function App() {
  const [token, setStoredToken] = useState<string>(() => getToken());
  const [draft, setDraft] = useState("");
  const [settingsOpen, setSettingsOpen] = useState(false);
  const newSessionOpen = useNewSessionStore((state) => state.isOpen);
  const newSessionPhase = useNewSessionStore((state) => state.phase);

  // Catch-up status refreshes (e.g. 750 ms after a new session is created —
  // iOS `.refresh` parity) bump this counter; the polling loop runs one tick.
  const tickRequestCount = useConnectionStore((state) => state.tickRequestCount);
  const tickRef = useRef<(() => void) | null>(null);
  useEffect(() => {
    if (tickRequestCount > 0) {
      void tickRef.current?.();
    }
  }, [tickRequestCount]);

  // One-time bootstrap: read #token=... from the URL fragment, store it, and
  // strip the fragment so the token never sits in the address bar.
  useEffect(() => {
    const match = /token=([^&]+)/.exec(window.location.hash);
    if (!match) {
      return;
    }
    const value = decodeURIComponent(match[1] ?? "");
    if (value) {
      setToken(value);
      setStoredToken(value);
    }
    window.history.replaceState(null, "", window.location.pathname + window.location.search);
  }, []);

  // Polling lifecycle: 2 s tick for /api/status + /api/notifications +
  // /api/feed + /api/log + /api/integrations/opencode (iOS global refresh
  // parity — HarnessFeatureConnectionReducer.refresh fetches all five in
  // parallel). Skipped while a tick is in flight (overlap guard) and while
  // the tab is hidden; an immediate tick fires when the tab becomes visible
  // again. Runs only while a token is stored.
  useEffect(() => {
    if (!token) {
      return;
    }
    let inFlight = false;
    let disposed = false;
    tickRef.current = null;

    const tick = async () => {
      if (disposed || inFlight || document.hidden) {
        return;
      }
      if (useConnectionStore.getState().manualDisconnect) {
        return;
      }
      inFlight = true;
      try {
        const [statusResult, notificationsResult, feedResult, logResult, integrationResult] =
          await Promise.allSettled([
            getStatus(),
            getNotifications(),
            getFeed(),
            getLog(),
            getOpenCodeIntegration(),
          ]);
        if (disposed) {
          return;
        }
        const connection = useConnectionStore.getState();
        const workspaces = useWorkspacesStore.getState();
        if (statusResult.status === "fulfilled") {
          connection.markStatus(statusResult.value);
          workspaces.applyStatus(statusResult.value);
        } else {
          connection.markPollError(statusResult.reason instanceof Error ? statusResult.reason.message : "Poll failed");
        }
        if (notificationsResult.status === "fulfilled") {
          workspaces.applyNotifications(notificationsResult.value);
        }
        if (feedResult.status === "fulfilled") {
          workspaces.applyFeed(feedResult.value);
        }
        if (logResult.status === "fulfilled") {
          workspaces.applyLog(logResult.value);
        }
        if (integrationResult.status === "fulfilled") {
          workspaces.applyOpenCodeIntegration(integrationResult.value);
        }
      } finally {
        inFlight = false;
      }
    };

    tickRef.current = tick;
    void tick();
    const intervalId = setInterval(() => void tick(), POLL_INTERVAL_MS);
    const onVisibilityChange = () => {
      if (document.visibilityState === "visible") {
        void tick();
      }
    };
    document.addEventListener("visibilitychange", onVisibilityChange);
    return () => {
      disposed = true;
      tickRef.current = null;
      clearInterval(intervalId);
      document.removeEventListener("visibilitychange", onVisibilityChange);
    };
  }, [token]);

  // Screen polling lifecycle: start when a session is selected, stop when the
  // selection changes or clears (iOS: the screen tick runs only for the
  // selected workspace).
  const selectedWorkspaceID = useWorkspacesStore((state) => state.selectedWorkspaceID);
  useEffect(() => {
    if (!token || !selectedWorkspaceID) {
      useSessionStore.getState().stopPolling();
      return;
    }
    useSessionStore.getState().startPolling();
    return () => useSessionStore.getState().stopPolling();
  }, [token, selectedWorkspaceID]);

  const saveToken = () => {
    const value = draft.trim();
    if (!value) {
      return;
    }
    setToken(value);
    setStoredToken(value);
    setDraft("");
  };

  const clearToken = () => {
    setToken("");
    setStoredToken("");
    useWorkspacesStore.setState({
      workspaces: [],
      notifications: [],
      feedItems: [],
      logEntries: [],
      openCodeIntegration: null,
      lastUpdated: null,
      hasReceivedStatus: false,
      selectedGroupID: null,
      selectedWorkspaceID: null,
    });
    useConnectionStore.setState({
      connection: "checking",
      lastUpdated: null,
      errorMessage: null,
      engineEnabled: null,
      consecutivePollFailures: 0,
      manualDisconnect: false,
    });
  };

  if (!token) {
    return (
      <main className="screen">
        <section className="card">
          <div className="card-icon" aria-hidden>
            <KeyRound size={22} />
          </div>
          <h1>Harness Web</h1>
          <p className="hint">
            Paste the token printed in the Mac server log
            (<code>harness-web ready: http://…/harness-web/#token=…</code>).
            It is kept only in this browser.
          </p>
          <input
            type="password"
            className="token-input"
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                saveToken();
              }
            }}
            placeholder="Token from server log"
            autoFocus
            autoComplete="off"
            spellCheck={false}
          />
          <button type="button" className="primary" onClick={saveToken} disabled={!draft.trim()}>
            Save
          </button>
        </section>
      </main>
    );
  }

  return (
    <div className="app">
      <ConnectionBar onClearToken={clearToken} onOpenSettings={() => setSettingsOpen(true)} />
      <Sidebar />
      <DetailPane />
      {newSessionOpen ? <NewSessionModal /> : null}
      {newSessionPhase !== "idle" ? <SessionCreationProgressOverlay /> : null}
      {settingsOpen ? (
        <SettingsModal
          onClose={() => setSettingsOpen(false)}
          onTokenChanged={(value) => setStoredToken(value)}
        />
      ) : null}
    </div>
  );
}

function DetailPane() {
  const workspaces = useWorkspacesStore((state) => state.workspaces);
  const selectedWorkspaceID = useWorkspacesStore((state) => state.selectedWorkspaceID);

  const workspace = workspaces.find((candidate) => workspaceID(candidate) === selectedWorkspaceID);

  if (!workspace) {
    return (
      <main className="detail">
        <div className="detail-placeholder">Select a session</div>
      </main>
    );
  }

  const group = groups(workspaces).find((candidate) => candidate.id === sessionGroupID(workspace));

  // Fallback group (shouldn't happen — the workspace is in the list).
  if (!group) {
    return (
      <main className="detail">
        <div className="detail-placeholder">Select a session</div>
      </main>
    );
  }

  return <WorkspaceDetailView key={workspace.uuid || workspace.index} workspace={workspace} group={group} />;
}
