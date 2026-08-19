import { useMemo, useState } from "react";
import { Menu, Search } from "lucide-react";
import { useConnectionStore } from "../../store/connectionStore";
import { useWorkspacesStore } from "../../store/workspacesStore";
import { getHashRoute, setHashRoute } from "../../lib/hashRoute";
import type { Pane } from "../../types/herdr";
import { useEscapeLayer, useScrollLock } from "../../hooks/useOverlay";
import {
  filterGroups,
  groups,
  WORKSPACE_FILTERS,
  type WorkspaceFilter,
} from "../../lib/workspaceGroups";
import { WorkspaceCardView } from "./WorkspaceCardView";
import { AttentionStrip } from "./AttentionStrip";
import "./workspace.css";

interface WorkspaceListViewProps {
  /** Opens the "chats" navigator drawer (visible below 1100 px only). */
  onOpenNavigator: () => void;
  /** Phone (<700 px): the list itself is an overlay drawer. */
  drawerOpen: boolean;
  onCloseDrawer: () => void;
}

/**
 * Middle column: the workspace list (iOS WorkspaceListView parity) —
 * "Workspaces" title, search, segmented filter (All / Needs you / Active,
 * lowercased render), attention strip (top 2), "spaces" section with
 * "n / total", cards, and the empty state. Below 700 px the whole column
 * is an overlay drawer (backdrop / Esc / "Close workspaces", same chrome as
 * the chats sidebar drawer).
 */
export function WorkspaceListView({ onOpenNavigator, drawerOpen, onCloseDrawer }: WorkspaceListViewProps) {
  const data = useWorkspacesStore((state) => state.data);
  const selectedWorkspaceId = useWorkspacesStore((state) => state.selectedWorkspaceId);
  const selectedPaneId = useWorkspacesStore((state) => state.selectedPaneId);
  const connectionStatus = useConnectionStore((state) => state.status);

  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<WorkspaceFilter>("all");
  // Demo banner dismiss — per render only, never persisted (iOS keeps the
  // banner in the workspace header while demo is active).
  const [demoBannerDismissed, setDemoBannerDismissed] = useState(false);

  // Drawer hygiene (same overlay pattern as the chats sidebar): Esc closes,
  // body scroll locks while open.
  useEscapeLayer(onCloseDrawer, drawerOpen);
  useScrollLock(drawerOpen);

  const all = useMemo(() => groups(data?.workspaces ?? []), [data]);
  const visible = useMemo(() => filterGroups(all, search, filter), [all, search, filter]);
  const panesByWorkspace = useMemo(() => {
    const map = new Map<string, Pane[]>();
    for (const workspace of data?.workspaces ?? []) map.set(workspace.workspace_id, workspace.panes);
    return map;
  }, [data]);

  // Radar cell click: select the pane and close the attention deck (deck=1)
  // if it is open. replaceState fires no hashchange, so a synthetic event
  // lets App re-read the deck param. Selecting from the phone drawer also
  // closes it (tapping the already-selected workspace included).
  const selectPane = (workspaceId: string, paneId: string) => {
    useWorkspacesStore.getState().repairSelection(workspaceId, paneId);
    if (drawerOpen) onCloseDrawer();
    const route = getHashRoute();
    if (route.params.deck === undefined) return;
    const params = { ...route.params };
    delete params.deck;
    setHashRoute({ ...route, params });
    window.dispatchEvent(new HashChangeEvent("hashchange"));
  };

  return (
    <section
      className={`hz-ws-list${drawerOpen ? " hz-ws-list-open" : ""}`}
      aria-label="Workspaces"
    >
      <header className="hz-ws-list-header">
        <button
          type="button"
          className="hz-nav-toggle"
          onClick={onOpenNavigator}
          aria-label="Open navigator"
        >
          <Menu size={16} aria-hidden />
        </button>
        <h1 className="hz-ws-list-title">Workspaces</h1>
        {drawerOpen ? (
          <button type="button" className="hz-ws-list-close" onClick={onCloseDrawer}>
            Close workspaces
          </button>
        ) : null}
        {connectionStatus === "Demo" && !demoBannerDismissed ? (
          <div className="hz-demo-banner" role="status">
            <span>Demo data is active</span>
            <button
              type="button"
              className="hz-demo-banner-dismiss"
              onClick={() => setDemoBannerDismissed(true)}
              aria-label="Dismiss demo banner"
            >
              ×
            </button>
          </div>
        ) : null}
      </header>

      <div className="hz-ws-toolbar">
        <label className="hz-ws-search">
          <Search size={14} className="hz-ws-search-icon" aria-hidden="true" />
          <input
            className="hz-ws-search-input"
            type="text"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            placeholder="filter spaces"
            aria-label="filter spaces"
            autoComplete="off"
            autoCapitalize="off"
            spellCheck={false}
          />
        </label>
        <div className="hz-ws-filter" role="group" aria-label="Filter workspaces">
          {WORKSPACE_FILTERS.map((option) => (
            <button
              key={option.id}
              type="button"
              className={`hz-ws-filter-option${filter === option.id ? " hz-ws-filter-option-active" : ""}`}
              aria-pressed={filter === option.id}
              onClick={() => setFilter(option.id)}
            >
              {option.rendered}
            </button>
          ))}
        </div>
      </div>

      <AttentionStrip />

      <div className="hz-ws-section-header">
        <span className="hz-ws-section-label">spaces</span>
        <span className="hz-ws-section-detail">
          {visible.length} / {all.length}
        </span>
      </div>

      <div className="hz-ws-cards">
        {visible.length === 0 ? (
          <div className="hz-ws-empty">
            <p className="hz-ws-empty-title">No Herdr workspaces</p>
            <p className="hz-ws-empty-sub">Create a workspace here or on your Mac to begin.</p>
          </div>
        ) : null}
        {visible.map((group) => (
          <WorkspaceCardView
            key={group.workspaceId}
            group={group}
            selected={selectedWorkspaceId === group.workspaceId}
            onSelect={() => {
              useWorkspacesStore.getState().repairSelection(group.workspaceId, null);
              if (drawerOpen) onCloseDrawer();
            }}
            panes={panesByWorkspace.get(group.workspaceId) ?? []}
            selectedPaneId={selectedPaneId}
            onSelectPane={(paneId) => selectPane(group.workspaceId, paneId)}
          />
        ))}
      </div>
    </section>
  );
}
