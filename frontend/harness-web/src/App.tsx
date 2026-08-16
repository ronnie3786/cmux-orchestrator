import { useEffect, useState } from "react";
import { KeyRound, Loader2, RefreshCw } from "lucide-react";
import { getToken, setToken } from "./api/client";
import { getStatus, type HarnessStatus } from "./api/endpoints";

type ConnectionState =
  | { status: "idle" }
  | { status: "checking" }
  | { status: "ok"; detail: HarnessStatus }
  | { status: "error"; message: string };

export default function App() {
  const [token, setStoredToken] = useState<string>(() => getToken());
  const [draft, setDraft] = useState("");
  const [connection, setConnection] = useState<ConnectionState>({ status: "idle" });

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

  const saveToken = () => {
    const value = draft.trim();
    if (!value) {
      return;
    }
    setToken(value);
    setStoredToken(value);
    setDraft("");
    setConnection({ status: "idle" });
  };

  const testConnection = async () => {
    setConnection({ status: "checking" });
    try {
      const status = await getStatus();
      setConnection({ status: "ok", detail: status });
    } catch (error) {
      setConnection({
        status: "error",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  };

  const clearToken = () => {
    setToken("");
    setStoredToken("");
    setConnection({ status: "idle" });
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
    <main className="screen">
      <section className="card">
        <h1>Harness Web</h1>
        <p className="connected">Connected to harness</p>
        <button
          type="button"
          className="primary"
          onClick={testConnection}
          disabled={connection.status === "checking"}
        >
          {connection.status === "checking" ? (
            <Loader2 size={16} className="spin" aria-hidden />
          ) : (
            <RefreshCw size={16} aria-hidden />
          )}
          Test connection
        </button>
        {connection.status === "ok" && (
          <p className="result ok">
            /api/status responded — {connection.detail.workspaces.length} workspace
            {connection.detail.workspaces.length === 1 ? "" : "s"}, socket{" "}
            {connection.detail.socketFound ? "found" : "missing"}.
          </p>
        )}
        {connection.status === "error" && (
          <div className="result error">
            <p>{connection.message}</p>
            <button type="button" className="ghost" onClick={clearToken}>
              Change token
            </button>
          </div>
        )}
        <p className="hint">Real screens (sessions, terminal, Git) land in later phases.</p>
      </section>
    </main>
  );
}
