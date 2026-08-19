import { useEffect, useState } from "react";
import { Lock, Settings, X } from "lucide-react";
import { getServerUrl, getStoredServerUrl } from "../../api/client";
import { pushStatus } from "../../api/herdr";
import { useConnectionStore } from "../../store/connectionStore";
import { useWorkspacesStore } from "../../store/workspacesStore";
import { useEscapeLayer, useScrollLock } from "../../hooks/useOverlay";
import { disableDemoMode, demoEnabled, enableDemoMode } from "../../demo/demoAdapter";
import { validateServerUrl } from "../Onboarding/OnboardingView";
import "./settings.css";

interface SettingsModalProps {
  onClose: () => void;
  /**
   * Persist `serverUrl`, exit demo mode if active, and re-probe + restart
   * the stream (owned by App — the token is kept; a 401 re-enters
   * onboarding via the client's onUnauthorized hook).
   */
  onReconnect: (serverUrl: string) => void;
}

/** doc 01 §6: apns unconfigured → local alerts; configured → verified. */
const DELIVERY_LOCAL = "Local alerts while the app is connected";
const DELIVERY_VERIFIED = "Background delivery verified";

function relativeTime(timestamp: number | null): string {
  if (timestamp === null) {
    return "—";
  }
  const seconds = Math.max(0, Math.round((Date.now() - timestamp) / 1000));
  if (seconds < 5) return "just now";
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  return `${Math.round(minutes / 60)}h ago`;
}

/**
 * Web settings sheet (iOS SettingsView parity, re-pointed at the herdr
 * surfaces): Connection status + server URL + demo toggle, Attention
 * (alert semantics + delivery status), Private by design, About.
 */
export function SettingsModal({ onClose, onReconnect }: SettingsModalProps) {
  const demo = useConnectionStore((state) => state.demo);
  const lastUpdated = useWorkspacesStore((state) => state.lastUpdated);
  const data = useWorkspacesStore((state) => state.data);

  const [serverUrl, setServerUrl] = useState(() => getServerUrl());
  const [urlError, setUrlError] = useState<string | null>(null);
  const [delivery, setDelivery] = useState<string | null>(null);

  useEscapeLayer(onClose);
  useScrollLock(true);

  const workspaces = data?.workspaces ?? [];
  const paneCount = workspaces.reduce((total, workspace) => total + workspace.panes.length, 0);

  // Delivery row: /push/status on open, live mode only (demo has no server).
  useEffect(() => {
    if (demoEnabled()) {
      setDelivery(DELIVERY_LOCAL);
      return;
    }
    let cancelled = false;
    setDelivery(null);
    void pushStatus()
      .then((status) => {
        if (cancelled) return;
        setDelivery(status.apns.configured ? DELIVERY_VERIFIED : DELIVERY_LOCAL);
      })
      .catch(() => {
        if (!cancelled) setDelivery(DELIVERY_LOCAL);
      });
    return () => {
      cancelled = true;
    };
  }, [demo]);

  const saveAndReconnect = () => {
    const error = validateServerUrl(serverUrl);
    if (error !== null) {
      setUrlError(error);
      return;
    }
    setUrlError(null);
    onReconnect(serverUrl.trim());
    onClose();
  };

  const toggleDemo = () => {
    if (demo) {
      disableDemoMode();
      onReconnect(getServerUrl());
      onClose();
    } else {
      enableDemoMode();
    }
  };

  return (
    <div
      className="hb-dialog-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <div
        className="hb-settings"
        role="dialog"
        aria-modal="true"
        aria-label="Settings"
      >
        <div className="hb-settings-title">
          <span>
            <Settings size={15} aria-hidden /> Settings
          </span>
          <button type="button" className="hb-settings-close" onClick={onClose} aria-label="Close">
            <X size={16} />
          </button>
        </div>

        <div className="hb-settings-body">
          {/* Connection */}
          <section className="hb-settings-section">
            <h3>Connection</h3>
            <div className="hb-settings-row">
              <span className="hb-settings-row-label">Server</span>
              <span className="hb-settings-row-value mono">
                {getStoredServerUrl() ?? "This origin"}
              </span>
            </div>
            <div className="hb-settings-row">
              <span className="hb-settings-row-label">Workspaces</span>
              <span className="hb-settings-row-value">{workspaces.length}</span>
            </div>
            <div className="hb-settings-row">
              <span className="hb-settings-row-label">Live panes</span>
              <span className="hb-settings-row-value">{paneCount}</span>
            </div>
            <div className="hb-settings-row">
              <span className="hb-settings-row-label">Last update</span>
              <span className="hb-settings-row-value">{relativeTime(lastUpdated)}</span>
            </div>

            <label className="hb-settings-field-label" htmlFor="hb-settings-server-url">
              Server URL
            </label>
            <input
              id="hb-settings-server-url"
              type="url"
              className="hb-settings-input"
              value={serverUrl}
              onChange={(event) => setServerUrl(event.target.value)}
              autoComplete="off"
              autoCapitalize="off"
              spellCheck={false}
            />
            {urlError !== null ? (
              <p className="hb-settings-error" role="alert">
                {urlError}
              </p>
            ) : null}
            <button type="button" className="hb-settings-action" onClick={saveAndReconnect}>
              Save and reconnect
            </button>
            {demo ? (
              <button type="button" className="hb-settings-action" onClick={saveAndReconnect}>
                Connect a real server
              </button>
            ) : null}

            <div className="hb-settings-row">
              <div className="hb-settings-row-main">
                <span className="hb-settings-row-label">Use demo data</span>
                <span className="hb-settings-row-sub">
                  Live-looking fixtures, no server or token required.
                </span>
              </div>
              <button
                type="button"
                role="switch"
                aria-checked={demo}
                aria-label="Use demo data"
                className={`hb-switch${demo ? " hb-switch-on" : ""}`}
                onClick={toggleDemo}
              />
            </div>
          </section>

          {/* Attention */}
          <section className="hb-settings-section">
            <h3>Attention</h3>
            <div className="hb-settings-row">
              <div className="hb-settings-row-main">
                <span className="hb-settings-row-label">Smart agent alerts</span>
                <span className="hb-settings-row-sub">
                  Blocked first, then unseen completions. The queue stays quiet until there's
                  a decision worth making.
                </span>
              </div>
            </div>
            <div className="hb-settings-row">
              <div className="hb-settings-row-main">
                <span className="hb-settings-row-label">Delivery</span>
                <span className="hb-settings-row-sub">{delivery ?? "Checking…"}</span>
              </div>
            </div>
          </section>

          {/* Private by design */}
          <section className="hb-settings-section">
            <h3>Private by design</h3>
            <div className="hb-private-row">
              <Lock size={13} aria-hidden />
              <span>The raw Herdr socket never leaves your Mac</span>
            </div>
            <div className="hb-private-row">
              <Lock size={13} aria-hidden />
              <span>Terminal control requires your pairing token</span>
            </div>
            <div className="hb-private-row">
              <Lock size={13} aria-hidden />
              <span>Tailscale keeps the server inside your tailnet</span>
            </div>
          </section>

          {/* About */}
          <section className="hb-settings-section">
            <h3>About</h3>
            <div className="hb-settings-row">
              <span className="hb-settings-row-label">herdr</span>
              <span className="hb-settings-row-value">Remote command deck · 0.1</span>
            </div>
          </section>
        </div>
      </div>
    </div>
  );
}
