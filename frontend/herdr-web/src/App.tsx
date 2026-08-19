import { useEffect, useState } from "react";
import { apiRequest, configureClient, getToken, setToken } from "./api/client";

interface HealthResponse {
  ok?: boolean;
  herdr?: { connected?: boolean };
}

/**
 * P0 placeholder: token gate + /health probe only. Later phases replace this
 * with the full herdr UI; the token form and the onUnauthorized hook-up are
 * the durable parts.
 */
export default function App() {
  const [token, setStoredToken] = useState<string>(() => getToken());
  const [draft, setDraft] = useState("");
  const [health, setHealth] = useState<HealthResponse | null>(null);

  const clearToken = () => {
    setToken("");
    setStoredToken("");
    setHealth(null);
  };

  // Any 401 from the API re-enters onboarding (client contract).
  useEffect(() => {
    configureClient({ onUnauthorized: clearToken });
    // Stable setters — register once.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (!token) {
      return;
    }
    let cancelled = false;
    setHealth(null);
    apiRequest<HealthResponse>("/health")
      .then((result) => {
        if (!cancelled) {
          setHealth(result);
        }
      })
      .catch(() => {
        // Non-401 failures stay on the placeholder; 401 is handled by
        // onUnauthorized above (clears the token and shows the form).
      });
    return () => {
      cancelled = true;
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

  const connected = health?.herdr?.connected;
  return (
    <main className="screen">
      <section className="card">
        <h1>connected</h1>
        <p className="hint">herdr.connected: {connected === undefined ? "…" : String(connected)}</p>
      </section>
    </main>
  );
}
