import { useEffect, useState } from "react";
import { Check, Copy, Network, Plus, Settings, Trash2, X } from "lucide-react";
import { getNetworkInfo } from "../../api/endpoints";
import { getToken, setToken } from "../../api/client";
import { useEscapeLayer, useScrollLock } from "../../hooks/useOverlay";
import type { NetworkInfoResponse } from "../../api/types";
import { useConnectionStore } from "../../store/connectionStore";
import { useSourcesStore } from "../../store/sourcesStore";

interface SettingsModalProps {
  onClose: () => void;
  /** App owns the token state; this callback syncs a changed token into it. */
  onTokenChanged: (token: string) => void;
}

const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "::1", "[::1]"]);

/**
 * Web settings sheet. Scope follows the plan decisions:
 *  - engine toggle (the "Auto Reconnect" chip's setting, always reachable)
 *  - token: display / copy / change (existing localStorage flow)
 *  - saved server sources in localStorage `harness-web:sources`
 *    (informational — the app is served by the server it talks to)
 *  - network info from /api/network (the server knows its own addresses)
 */
export function SettingsModal({ onClose, onTokenChanged }: SettingsModalProps) {
  const engineEnabled = useConnectionStore((s) => s.engineEnabled);
  const isTogglingEngine = useConnectionStore((s) => s.isTogglingEngine);
  const setEngineEnabled = useConnectionStore((s) => s.setEngineEnabled);

  const sources = useSourcesStore((s) => s.sources);
  const activeId = useSourcesStore((s) => s.activeId);
  const { addSource, deleteSource, selectSource } = useSourcesStore();

  const [token, setTokenValue] = useState(() => getToken() ?? "");
  const [revealed, setRevealed] = useState(false);
  const [copied, setCopied] = useState(false);
  const [changingToken, setChangingToken] = useState(false);
  const [tokenDraft, setTokenDraft] = useState("");

  const [sourceName, setSourceName] = useState("");
  const [sourceUrl, setSourceUrl] = useState("");
  const [sourceError, setSourceError] = useState<string | null>(null);

  const [network, setNetwork] = useState<NetworkInfoResponse | null>(null);
  const [networkError, setNetworkError] = useState<string | null>(null);

  // Escape closes (iOS: toolbar X / swipe down) — top-most layer only.
  useEscapeLayer(onClose);
  useScrollLock(true);

  // The server knows its own addresses better than the browser does.
  useEffect(() => {
    let cancelled = false;
    getNetworkInfo()
      .then((response) => {
        if (!cancelled) setNetwork(response);
      })
      .catch((error: unknown) => {
        if (!cancelled) {
          setNetworkError(error instanceof Error ? error.message : "Couldn't load network info.");
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  async function copyToken() {
    if (!token) return;
    try {
      await navigator.clipboard.writeText(token);
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    } catch {
      // Clipboard unavailable (permissions) — the token stays visible.
    }
  }

  function saveToken() {
    const value = tokenDraft.trim();
    if (!value) return;
    setToken(value);
    setTokenValue(value);
    setTokenDraft("");
    setChangingToken(false);
    onTokenChanged(value);
  }

  function saveSource() {
    const error = addSource(sourceName, sourceUrl);
    if (error) {
      setSourceError(error);
      return;
    }
    setSourceName("");
    setSourceUrl("");
    setSourceError(null);
  }

  const host = window.location.hostname;
  const isLoopback = LOOPBACK_HOSTS.has(host);
  const activeSource = sources.find((s) => s.id === activeId) ?? null;
  const engineOn = engineEnabled === true;

  return (
    <div
      className="dialog-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <div className="dialog dialog-wide settings-dialog" role="dialog" aria-modal="true" aria-label="Settings">
        <div className="dialog-title">
          <span className="settings-title">
            <Settings size={15} aria-hidden /> Settings
          </span>
          <button type="button" className="icon-button" onClick={onClose} aria-label="Close">
            <X size={16} />
          </button>
        </div>

        <div className="settings-body">
          {/* Connection */}
          <section className="settings-section">
            <h3 className="settings-section-title">Connection</h3>
            <div className="settings-row">
              <div className="settings-row-main">
                <span className="settings-row-label">Auto Reconnect</span>
                <span className="settings-row-sub">Server engine keeps the cmux socket attached.</span>
              </div>
              <button
                type="button"
                role="switch"
                aria-checked={engineOn}
                aria-label="Auto Reconnect"
                className={`switch${engineOn ? " switch-on" : ""}`}
                onClick={() => void setEngineEnabled(!engineOn)}
                disabled={isTogglingEngine || engineEnabled == null}
              />
            </div>
          </section>

          {/* Token */}
          <section className="settings-section">
            <h3 className="settings-section-title">Token</h3>
            {changingToken ? (
              <div className="settings-token-change">
                <input
                  className="dialog-input"
                  type="password"
                  value={tokenDraft}
                  onChange={(event) => setTokenDraft(event.target.value)}
                  placeholder="Paste a new token"
                  spellCheck={false}
                  autoFocus
                />
                <div className="dialog-actions">
                  <button type="button" className="btn btn-secondary" onClick={() => setChangingToken(false)}>
                    Cancel
                  </button>
                  <button
                    type="button"
                    className="btn btn-primary"
                    onClick={saveToken}
                    disabled={tokenDraft.trim().length === 0}
                  >
                    Save
                  </button>
                </div>
              </div>
            ) : (
              <div className="settings-row">
                <code className="token-display" title={revealed ? undefined : "Click to reveal"}>
                  {token ? (revealed ? token : `${"•".repeat(10)}${token.slice(-4)}`) : "No token"}
                </code>
                <div className="settings-row-actions">
                  {token && (
                    <>
                      <button
                        type="button"
                        className="btn btn-secondary btn-small"
                        onClick={() => setRevealed((value) => !value)}
                      >
                        {revealed ? "Hide" : "Reveal"}
                      </button>
                      <button type="button" className="icon-button" onClick={() => void copyToken()} aria-label="Copy token">
                        {copied ? <Check size={15} className="icon-ok" /> : <Copy size={15} />}
                      </button>
                      <button
                        type="button"
                        className="btn btn-secondary btn-small"
                        onClick={() => {
                          setTokenDraft(token);
                          setChangingToken(true);
                        }}
                      >
                        Change
                      </button>
                    </>
                  )}
                </div>
              </div>
            )}
          </section>

          {/* Server sources (informational) */}
          <section className="settings-section">
            <h3 className="settings-section-title">Server</h3>
            <p className="settings-note">
              This page is served by the server it talks to — saved sources are for reference only.
            </p>
            <div className="settings-row">
              <div className="settings-row-main">
                <span className="settings-row-label">Connected to</span>
                <span className="settings-row-sub">
                  {window.location.host} · {isLoopback ? "loopback" : "network address"}
                </span>
              </div>
              <Network size={15} className="settings-row-icon" aria-hidden />
            </div>

            {sources.length > 0 && (
              <div className="source-list">
                {sources.map((source) => (
                  <div key={source.id} className="source-row">
                    <div className="settings-row-main">
                      <span className="settings-row-label">
                        {source.name || source.url}
                        {source.id === activeId && <span className="source-active-tag">active</span>}
                      </span>
                      <span className="settings-row-sub mono">{source.url}</span>
                    </div>
                    <div className="settings-row-actions">
                      {source.id !== activeId && (
                        <button
                          type="button"
                          className="btn btn-secondary btn-small"
                          onClick={() => selectSource(source.id)}
                        >
                          Use
                        </button>
                      )}
                      <button
                        type="button"
                        className="icon-button"
                        onClick={() => deleteSource(source.id)}
                        aria-label={`Delete ${source.name || source.url}`}
                      >
                        <Trash2 size={14} />
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            )}
            {activeSource == null && sources.length === 0 && (
              <p className="settings-note">No saved sources yet.</p>
            )}

            <div className="source-add">
              <div className="source-add-row">
                <input
                  className="dialog-input"
                  value={sourceName}
                  onChange={(event) => setSourceName(event.target.value)}
                  placeholder="Name"
                  spellCheck={false}
                />
                <input
                  className="dialog-input"
                  value={sourceUrl}
                  onChange={(event) => setSourceUrl(event.target.value)}
                  placeholder="http://host:9091"
                  spellCheck={false}
                  autoComplete="off"
                />
              </div>
              {sourceError && (
                <p className="dialog-error" role="alert">
                  {sourceError}
                </p>
              )}
              <div className="dialog-actions">
                <button
                  type="button"
                  className="btn btn-secondary btn-small"
                  onClick={saveSource}
                  disabled={sourceUrl.trim().length === 0}
                >
                  <Plus size={13} aria-hidden /> Add
                </button>
              </div>
            </div>
          </section>

          {/* Network info */}
          <section className="settings-section">
            <h3 className="settings-section-title">Network</h3>
            {networkError && <p className="dialog-error">{networkError}</p>}
            {!networkError && !network && <p className="settings-note">Loading network info…</p>}
            {network && (
              <div className="network-list">
                {network.port != null && (
                  <div className="network-row">
                    <span className="network-label">Port</span>
                    <span className="network-value">{network.port}</span>
                  </div>
                )}
                {network.hostname && (
                  <div className="network-row">
                    <span className="network-label">Hostname</span>
                    <span className="network-value mono">{network.hostname}</span>
                  </div>
                )}
                {network.localName && (
                  <div className="network-row">
                    <span className="network-label">Local</span>
                    <span className="network-value mono">http://{network.localName}:{network.port ?? ""}</span>
                  </div>
                )}
                {(network.lanAddresses?.length ?? 0) > 0 && (
                  <div className="network-row">
                    <span className="network-label">LAN</span>
                    <span className="network-value mono">
                      {(network.lanAddresses ?? []).map((address) => `http://${address}:${network.port ?? ""}`).join(" · ")}
                    </span>
                  </div>
                )}
                {network.tailscaleHost && (
                  <div className="network-row">
                    <span className="network-label">Tailscale</span>
                    <span className="network-value mono">http://{network.tailscaleHost}:{network.port ?? ""}</span>
                  </div>
                )}
              </div>
            )}
          </section>
        </div>
      </div>
    </div>
  );
}
