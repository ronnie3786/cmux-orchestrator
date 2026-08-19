import { useState } from "react";
import { ShieldCheck } from "lucide-react";
import { DEFAULT_SERVER_URL, getServerUrl } from "../../api/client";
import "./onboarding.css";

/** Byte-exact (doc 01 §6, iOS `connect()` failure copy). */
export const HTTPS_REQUIRED_ERROR = "Use HTTPS, or HTTP only when connecting to localhost.";
export const URL_REQUIRED_ERROR = "A server URL is required.";

const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);

/**
 * iOS `ServerConfiguration` URL policy, verbatim: https anywhere; http
 * only for loopback hosts. Returns the error message, or null when valid.
 */
export function validateServerUrl(raw: string): string | null {
  const url = raw.trim();
  if (!url) {
    return URL_REQUIRED_ERROR;
  }
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return HTTPS_REQUIRED_ERROR;
  }
  if (parsed.protocol === "https:") {
    return null;
  }
  if (parsed.protocol === "http:") {
    const host = parsed.hostname.toLowerCase().replace(/^\[|\]$/g, "");
    if (LOOPBACK_HOSTS.has(host)) {
      return null;
    }
  }
  return HTTPS_REQUIRED_ERROR;
}

/**
 * Prefill: the persisted server URL (Settings "Save and reconnect") or the
 * current origin — so opening the app served by the harness pre-fills the
 * harness itself and the token-only flow behaves exactly as before.
 */
export function prefillServerUrl(): string {
  const configured = getServerUrl();
  if (configured !== DEFAULT_SERVER_URL) {
    return configured;
  }
  if (typeof window !== "undefined" && window.location.origin.startsWith("http")) {
    return window.location.origin;
  }
  return DEFAULT_SERVER_URL;
}

interface OnboardingViewProps {
  /** Store the token + point the client at `serverUrl`, then probe. */
  onConnect: (serverUrl: string, token: string) => void;
  /** Enter the app in demo mode without a token. */
  onExploreDemo: () => void;
}

/**
 * Full-screen first-run view (iOS OnboardingView parity): brand block,
 * "Know where to look." promise, the "Connect to your Mac" form, and the
 * demo entry. Replaces the old bare token form when no token is stored.
 */
export function OnboardingView({ onConnect, onExploreDemo }: OnboardingViewProps) {
  const [serverUrl, setServerUrl] = useState(() => prefillServerUrl());
  const [token, setToken] = useState("");
  const [error, setError] = useState<string | null>(null);

  const connect = () => {
    const urlError = validateServerUrl(serverUrl);
    if (urlError !== null) {
      setError(urlError);
      return;
    }
    setError(null);
    onConnect(serverUrl.trim(), token.trim());
  };

  return (
    <main className="hb-onboarding">
      <div className="hb-onboarding-scroll">
        <header className="hb-onboarding-brand">
          <div className="hb-onboarding-mark" aria-hidden />
          <h1>herdr</h1>
          <p className="hb-onboarding-tagline">Your agents, within reach</p>
        </header>

        <section className="hb-onboarding-promise">
          <h2>Know where to look.</h2>
          <p>
            Move from workspace to pane to live agent in seconds. Herdr keeps the terminals
            real; this app keeps the decisions close.
          </p>
        </section>

        <section className="hb-onboarding-card" aria-label="Connect to your Mac">
          <h2>Connect to your Mac</h2>
          <label className="hb-onboarding-label" htmlFor="hb-server-url">
            Server URL
          </label>
          <input
            id="hb-server-url"
            type="url"
            className="hb-onboarding-input"
            value={serverUrl}
            onChange={(event) => setServerUrl(event.target.value)}
            placeholder="https://your-mac.tailnet.ts.net"
            autoComplete="off"
            autoCapitalize="off"
            spellCheck={false}
          />
          <label className="hb-onboarding-label" htmlFor="hb-pairing-token">
            Pairing token
          </label>
          <input
            id="hb-pairing-token"
            type="password"
            className="hb-onboarding-input"
            value={token}
            onChange={(event) => setToken(event.target.value)}
            autoComplete="off"
            spellCheck={false}
          />
          {error !== null ? (
            <p className="hb-onboarding-error" role="alert">
              {error}
            </p>
          ) : null}
          <button
            type="button"
            className="hb-onboarding-connect"
            onClick={connect}
            disabled={token.trim().length === 0}
          >
            Connect
          </button>
          <p className="hb-onboarding-footnote">
            <ShieldCheck size={13} aria-hidden />
            <span>
              Use the private HTTPS URL from tailscale serve status, or localhost for this
              Mac. The token stays in this browser via localStorage.
            </span>
          </p>
        </section>

        <button type="button" className="hb-onboarding-demo" onClick={onExploreDemo}>
          Explore with live-looking demo data
        </button>
      </div>
    </main>
  );
}
