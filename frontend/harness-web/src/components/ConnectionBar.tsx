/**
 * Top connection bar (iOS DashboardSummaryView parity).
 *
 * Left:  brand + editable server host (display/bookkeeping — same-origin fetch
 *        never uses it).
 * Right: status dot + title, "Updated HH:MM", auto-reconnect chip (visible
 *        while the server is reachable but not connected, iOS parity).
 */

import { CheckCircle2, Menu, PauseCircle, Settings } from "lucide-react";
import { useConnectionStore, type ConnectionState } from "../store/connectionStore";

function connectionTitle(connection: ConnectionState): string {
  switch (connection) {
    case "connected":
      return "Connected";
    case "reconnecting":
      return "Reconnecting";
    case "noSocket":
      return "No Connection";
    case "checking":
      return "Connecting…";
  }
}

function formatUpdated(epochMs: number): string {
  const date = new Date(epochMs);
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  return `${hours}:${minutes}`;
}

interface ConnectionBarProps {
  /** Phase 0 parity: lets the user wipe the stored token and re-paste. */
  onClearToken?: () => void;
  /** Opens the settings sheet (iOS HomeHeaderView gear parity). */
  onOpenSettings: () => void;
  /** Toggles the responsive sidebar drawer (visible <900 px only). */
  onToggleSidebar: () => void;
  sidebarOpen: boolean;
}

export function ConnectionBar({
  onClearToken,
  onOpenSettings,
  onToggleSidebar,
  sidebarOpen,
}: ConnectionBarProps) {
  const serverHost = useConnectionStore((state) => state.serverHost);
  const setServerHost = useConnectionStore((state) => state.setServerHost);
  const connection = useConnectionStore((state) => state.connection);
  const lastUpdated = useConnectionStore((state) => state.lastUpdated);
  const engineEnabled = useConnectionStore((state) => state.engineEnabled);
  const isTogglingEngine = useConnectionStore((state) => state.isTogglingEngine);
  const setEngineEnabled = useConnectionStore((state) => state.setEngineEnabled);

  // iOS parity: the chip appears on the connection card only while the server
  // is reachable (we have status) but not fully connected.
  const showReconnectChip = engineEnabled !== null && connection !== "connected";

  return (
    <header className="connection-bar">
      {/* Responsive drawer toggle (hidden ≥900 px — the sidebar is always visible). */}
      <button
        type="button"
        className="icon-button icon-button-light sidebar-toggle"
        onClick={onToggleSidebar}
        title={sidebarOpen ? "Close session list" : "Open session list"}
        aria-label={sidebarOpen ? "Close session list" : "Open session list"}
        aria-expanded={sidebarOpen}
        aria-controls="session-sidebar"
      >
        <Menu size={16} />
      </button>
      <div className="connection-bar-brand" title="cmux harness">
        cmux
      </div>
      <input
        className="connection-bar-host"
        value={serverHost}
        onChange={(event) => setServerHost(event.target.value)}
        spellCheck={false}
        autoComplete="off"
        aria-label="Server host (display only — the app is served by the server)"
      />
      <div className="connection-bar-status">
        <span className={`status-dot status-dot-${connection}`} aria-hidden="true" />
        <span className="connection-bar-title">{connectionTitle(connection)}</span>
        {lastUpdated !== null && <span className="connection-bar-updated">Updated {formatUpdated(lastUpdated)}</span>}
      </div>
      {showReconnectChip && (
        <button
          type="button"
          className={`reconnect-chip reconnect-chip-${engineEnabled ? "on" : "off"}`}
          disabled={isTogglingEngine}
          onClick={() => setEngineEnabled(!engineEnabled)}
        >
          {engineEnabled ? (
            <CheckCircle2 size={14} aria-hidden="true" />
          ) : (
            <PauseCircle size={14} aria-hidden="true" />
          )}
          <span>{engineEnabled ? "Auto reconnect" : "Reconnect off"}</span>
        </button>
      )}
      {onClearToken && (
        <button type="button" className="token-button" onClick={onClearToken}>
          Change token
        </button>
      )}
      <button
        type="button"
        className="icon-button icon-button-light"
        onClick={onOpenSettings}
        title="Settings"
        aria-label="Settings"
      >
        <Settings size={16} />
      </button>
    </header>
  );
}
