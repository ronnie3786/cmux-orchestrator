import { useEffect, useState } from "react";
import { KeyRound } from "lucide-react";
import { getToken, setToken } from "./api/client";
import { getFeed, getNotifications, getStatus } from "./api/endpoints";
import { ConnectionBar } from "./components/ConnectionBar";
import { Sidebar } from "./components/Sidebar";
import { useConnectionStore } from "./store/connectionStore";
import { useWorkspacesStore } from "./store/workspacesStore";
import { paneDisplayName, sessionDisplayName, workspaceID } from "./lib/workspaceGroups";

const POLL_INTERVAL_MS = 2_000;

export default function App() {
  const [token, setStoredToken] = useState<string>(() => getToken());
  const [draft, setDraft] = useState("");

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
  // /api/feed (iOS global refresh parity). Skipped while a tick is in flight
  // (overlap guard) and while the tab is hidden; an immediate tick fires when
  // the tab becomes visible again. Runs only while a token is stored.
  useEffect(() => {
    if (!token) {
      return;
    }
    let inFlight = false;
    let disposed = false;

    const tick = async () => {
      if (disposed || inFlight || document.hidden) {
        return;
      }
      if (useConnectionStore.getState().manualDisconnect) {
        return;
      }
      inFlight = true;
      try {
        const [statusResult, notificationsResult, feedResult] = await Promise.allSettled([
          getStatus(),
          getNotifications(),
          getFeed(),
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
      } finally {
        inFlight = false;
      }
    };

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
      clearInterval(intervalId);
      document.removeEventListener("visibilitychange", onVisibilityChange);
    };
  }, [token]);

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
      <ConnectionBar onClearToken={clearToken} />
      <Sidebar />
      <DetailPane />
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

  return (
    <main className="detail">
      <header className="detail-header">
        <div className="detail-title">{sessionDisplayName(workspace)}</div>
        <div className="detail-subtitle">{paneDisplayName(workspace)}</div>
      </header>
      <div className="detail-placeholder">Terminal, Git, and tools land in Phase 2.</div>
    </main>
  );
}
