import { useMemo } from "react";
import { useAlertsStore } from "../../store/alertsStore";
import { attentionPanes, useWorkspacesStore } from "../../store/workspacesStore";
import { chatDisplayName, compactStatus, needsAttention } from "../../lib/workspaceGroups";
import "./workspace.css";

/**
 * Top-2 attention strip (iOS AttentionStrip parity): "attention" label +
 * count, "open queue" affordance (the deck lands in P3-run-B at #deck=1 —
 * the hash route preserves the unknown param), and the two most urgent
 * attention panes (blocked first, then done) as compact rows with a "NEW"
 * capsule on panes with an unread alert.
 */
export function AttentionStrip() {
  const data = useWorkspacesStore((state) => state.data);
  const alerts = useAlertsStore((state) => state.alerts);

  // Derived from data (stable snapshot) — the selector must not hand out a
  // fresh array on every render (zustand v5 getSnapshot identity).
  const ranked = useMemo(() => attentionPanes(useWorkspacesStore.getState()), [data]);

  const { rows, total, unseen, workspaceLabel } = useMemo(() => {
    const attention = ranked.filter((pane) => needsAttention(pane.agent_status));
    const labels = new Map((data?.workspaces ?? []).map((workspace) => [workspace.workspace_id, workspace.label]));
    const unseenPanes = new Set(alerts.filter((alert) => !alert.isRead).map((alert) => alert.paneId));
    return {
      rows: attention.slice(0, 2),
      total: attention.length,
      unseen: unseenPanes,
      workspaceLabel: (id: string) => labels.get(id) ?? id,
    };
  }, [data, ranked, alerts]);

  if (rows.length === 0) return null;

  return (
    <section className="hz-attention" aria-label="attention">
      <header className="hz-attention-header">
        <span className="hz-attention-label">attention</span>
        <span className="hz-attention-count">{total}</span>
        <a className="hz-attention-queue" href="#deck=1">
          open queue
        </a>
      </header>
      {rows.map((pane) => (
        <a
          key={pane.pane_id}
          className="hz-attention-row"
          href={`#ws=${encodeURIComponent(pane.workspace_id)}&pane=${encodeURIComponent(pane.pane_id)}`}
        >
          <span className={`hz-dot hz-dot-${pane.agent_status}`} aria-hidden />
          <span className="hz-attention-title">{chatDisplayName(pane)}</span>
          {unseen.has(pane.pane_id) ? <span className="hz-attention-new">NEW</span> : null}
          <span className="hz-attention-meta">
            {workspaceLabel(pane.workspace_id)} · {compactStatus(pane.agent_status)}
          </span>
        </a>
      ))}
    </section>
  );
}
