import { useEffect, useMemo } from "react";
import { alerts as fetchAlerts } from "../../api/herdr";
import { useAlertsStore } from "../../store/alertsStore";
import { useWorkspacesStore } from "../../store/workspacesStore";
import type { AgentStatus, Alert, Pane } from "../../types/herdr";
import { AlertCardView } from "./AlertCardView";
import "./attention.css";

interface AttentionViewProps {
  /** Clears deck=1 from the hash and closes the deck (App owns the state). */
  onClose: () => void;
}

/** Same attention ranking as workspacesStore.attentionPanes (lower = more urgent). */
const RANK: Record<AgentStatus, number> = {
  blocked: 0,
  done: 1,
  working: 2,
  idle: 3,
  unknown: 4,
};

/**
 * Live queue: UNREAD alerts ranked blocked → done → working → idle → unknown,
 * joining each alert to the pane's current agent_status via the snapshot.
 * Alerts whose pane is gone use the unknown ranking (last). Ties break by
 * createdAt descending (newest first).
 */
export function rankQueueAlerts(alerts: Alert[], panes: ReadonlyMap<string, Pane>): Alert[] {
  const rankOf = (alert: Alert): number => {
    const pane = panes.get(alert.paneId);
    return pane ? (RANK[pane.agent_status] ?? RANK.unknown) : RANK.unknown;
  };
  return alerts
    .filter((alert) => !alert.isRead)
    .sort((a, b) => rankOf(a) - rankOf(b) || Date.parse(b.createdAt) - Date.parse(a.createdAt));
}

/** Journal (Recent signals): newest first, capped to `limit` rows. */
export function recentAlerts(alerts: Alert[], limit = 10): Alert[] {
  return [...alerts].sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt)).slice(0, limit);
}

/**
 * The Attention Deck (iOS AttentionView parity) — right region when the hash
 * route contains `deck=1`. "Live queue" (unread, ranked) over "Recent signals"
 * (the journal). NEVER clear-on-load: the journal is dirty on day one; unread
 * state comes from the server and mark-read only via explicit user action.
 * Opening the deck seeds the store from GET /alerts (the /workspaces snapshot
 * list is capped and is not the unread source of truth).
 */
export function AttentionView({ onClose }: AttentionViewProps) {
  const data = useWorkspacesStore((state) => state.data);
  const alerts = useAlertsStore((state) => state.alerts);
  const unreadCount = useAlertsStore((state) => state.unreadCount);
  const markRead = useAlertsStore((state) => state.markRead);
  const readAll = useAlertsStore((state) => state.readAll);

  useEffect(() => {
    let cancelled = false;
    fetchAlerts()
      .then((response) => {
        if (!cancelled) useAlertsStore.getState().sync(response);
      })
      .catch(() => {
        // Absorbed: SSE upserts / the next deck open re-converge.
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const paneById = useMemo(() => {
    const map = new Map<string, Pane>();
    for (const workspace of data?.workspaces ?? []) {
      for (const pane of workspace.panes) map.set(pane.pane_id, pane);
    }
    return map;
  }, [data]);

  const queue = useMemo(() => rankQueueAlerts(alerts, paneById), [alerts, paneById]);
  const recent = useMemo(() => recentAlerts(alerts), [alerts]);

  const renderCard = (alert: Alert) => (
    <AlertCardView
      key={alert.id}
      alert={alert}
      pane={paneById.get(alert.paneId) ?? null}
      onMarkRead={(id) => {
        void markRead(id);
      }}
    />
  );

  return (
    <main className="hz-detail-col">
      <div className="hz-deck">
        <header className="hz-deck-header">
          <div className="hz-deck-title-row">
            <button
              type="button"
              className="hz-deck-back"
              onClick={onClose}
              aria-label="Back to pane view"
            >
              queue
            </button>
            <div className="hz-deck-titles">
              <h1 className="hz-deck-title">Attention</h1>
              <p className="hz-deck-subtitle">Attention deck</p>
            </div>
            {unreadCount > 0 ? (
              <button type="button" className="hz-deck-read-all" onClick={() => void readAll()}>
                read all
              </button>
            ) : null}
          </div>
          <p className="hz-deck-copy">
            Blocked first, then unseen completions. The queue stays quiet until there's a decision
            worth making.
          </p>
        </header>

        {alerts.length === 0 ? (
          <div className="hz-deck-empty">
            <p className="hz-deck-empty-title">Nothing needs you</p>
            <p className="hz-deck-empty-sub">
              Working agents will surface here when they finish or need a decision.
            </p>
          </div>
        ) : (
          <>
            {queue.length > 0 ? (
              <section className="hz-deck-section" aria-label="Live queue">
                <h2 className="hz-deck-section-label">Live queue</h2>
                {queue.map(renderCard)}
              </section>
            ) : null}
            {recent.length > 0 ? (
              <section className="hz-deck-section" aria-label="Recent signals">
                <h2 className="hz-deck-section-label">Recent signals</h2>
                {recent.map(renderCard)}
              </section>
            ) : null}
          </>
        )}
      </div>
    </main>
  );
}
