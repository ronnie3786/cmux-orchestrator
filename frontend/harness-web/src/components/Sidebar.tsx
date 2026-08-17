/**
 * Session sidebar (iOS WorkspaceListView / session card parity).
 *
 * Error banner (poll failures) on top, then session groups: a workspace row
 * (star toggle + name + unread badge) with one row per cmux surface/pane
 * (name + state badge: green "Session" / orange "Needs You"). Selecting a row
 * fires the selection side effects (push/clear, mark read) in the store.
 */

import { useState } from "react";
import { Check, ChevronDown, Search, SlidersHorizontal, Star } from "lucide-react";
import { useConnectionStore } from "../store/connectionStore";
import { useWorkspacesStore } from "../store/workspacesStore";
import { useEscapeLayer } from "../hooks/useOverlay";
import {
  filterGroups,
  groups,
  paneLabel,
  SESSION_FILTERS,
  unreadCountForGroup,
  workspaceID,
  workspaceNeedsYou,
  type SessionFilter,
} from "../lib/workspaceGroups";

function UnreadBadge({ count }: { count: number }) {
  if (count === 0) return null;
  return <span className="unread-badge">{count > 99 ? "99+" : count}</span>;
}

function StateBadge({ needsYou }: { needsYou: boolean }) {
  return (
    <span className={`state-badge ${needsYou ? "state-badge-needs-you" : "state-badge-session"}`}>
      {needsYou ? "Needs You" : "Session"}
    </span>
  );
}

interface SidebarProps {
  /** Responsive drawer (visible only below the 900 px breakpoint). */
  open?: boolean;
  /** Called when the drawer should close (row tap, backdrop tap, Escape). */
  onClose?: () => void;
}

export function Sidebar({ open = false, onClose }: SidebarProps) {
  const errorMessage = useConnectionStore((state) => state.errorMessage);
  const clearError = useConnectionStore((state) => state.clearError);
  const connect = useConnectionStore((state) => state.connect);
  const workspaces = useWorkspacesStore((state) => state.workspaces);
  const notifications = useWorkspacesStore((state) => state.notifications);
  const feedItems = useWorkspacesStore((state) => state.feedItems);
  const hasReceivedStatus = useWorkspacesStore((state) => state.hasReceivedStatus);
  const selectedWorkspaceID = useWorkspacesStore((state) => state.selectedWorkspaceID);
  const selectGroup = useWorkspacesStore((state) => state.selectGroup);
  const selectWorkspace = useWorkspacesStore((state) => state.selectWorkspace);
  const toggleStar = useWorkspacesStore((state) => state.toggleStar);

  // Search + filter (iOS SessionSearchFilterBar parity). Component-local state
  // — iOS keeps it in the feature state and does not persist it.
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<SessionFilter>("all");
  const [filterMenuOpen, setFilterMenuOpen] = useState(false);
  const filterLabel = SESSION_FILTERS.find((option) => option.id === filter)?.label ?? "All";

  // Escape closes the filter menu first (top-most layer), then the drawer.
  useEscapeLayer(() => setFilterMenuOpen(false), filterMenuOpen);

  // Escape closes the drawer when it is open (only the top-most layer
  // handles Esc — a modal opened over the drawer closes first).
  useEscapeLayer(() => onClose?.(), open);

  const close = () => onClose?.();

  const sessionGroups = groups(workspaces);
  const visibleGroups = filterGroups(sessionGroups, search, filter, {
    notifications,
    feedItems,
  });

  return (
    <>
      {open ? <div className="sidebar-backdrop" onClick={close} aria-hidden /> : null}
      <aside className={`sidebar${open ? " sidebar-open" : ""}`} id="session-sidebar">
      {errorMessage !== null && (
        <div className="error-banner" role="alert">
          <span className="error-banner-text">{errorMessage}</span>
          <div className="error-banner-actions">
            <button type="button" className="error-banner-button" onClick={connect}>
              Retry
            </button>
            <button type="button" className="error-banner-button" onClick={clearError}>
              Dismiss
            </button>
          </div>
        </div>
      )}

      {/* iOS SessionSearchFilterBar: search field + filter menu, top of sidebar. */}
      <div className="sidebar-toolbar">
        <label className="sidebar-search">
          <Search size={15} className="sidebar-search-icon" aria-hidden="true" />
          <input
            className="sidebar-search-input"
            type="text"
            value={search}
            placeholder="Search sessions..."
            onChange={(event) => setSearch(event.target.value)}
            autoComplete="off"
            autoCapitalize="off"
            spellCheck={false}
            aria-label="Search sessions"
          />
        </label>
        <div className="sidebar-filter">
          <button
            type="button"
            className="sidebar-filter-button"
            aria-haspopup="menu"
            aria-expanded={filterMenuOpen}
            onClick={() => setFilterMenuOpen((openState) => !openState)}
          >
            <SlidersHorizontal size={15} className="sidebar-filter-icon" aria-hidden="true" />
            <span className="sidebar-filter-label">{filterLabel}</span>
            <ChevronDown size={14} className="sidebar-filter-chevron" aria-hidden="true" />
          </button>
          {filterMenuOpen ? (
            <>
              <div className="menu-backdrop" onClick={() => setFilterMenuOpen(false)} />
              <div className="sidebar-filter-menu" role="menu">
                {SESSION_FILTERS.map((option) => (
                  <button
                    key={option.id}
                    type="button"
                    role="menuitemradio"
                    aria-checked={filter === option.id}
                    className="menu-item"
                    onClick={() => {
                      setFilter(option.id);
                      setFilterMenuOpen(false);
                    }}
                  >
                    <span className="menu-item-label">{option.label}</span>
                    {filter === option.id ? <Check size={14} className="menu-item-check" /> : null}
                  </button>
                ))}
              </div>
            </>
          ) : null}
        </div>
      </div>

      <div className="sidebar-list">
        {!hasReceivedStatus && (
          <div className="sidebar-empty sidebar-empty-loading">
            <span className="spinner spinner-small" aria-hidden />
            Connecting…
          </div>
        )}
        {hasReceivedStatus && sessionGroups.length === 0 && <div className="sidebar-empty">No sessions</div>}
        {hasReceivedStatus && sessionGroups.length > 0 && visibleGroups.length === 0 && (
          <div className="sidebar-empty sidebar-empty-no-matches">
            <span className="sidebar-empty-title">No Matches</span>
            <span className="sidebar-empty-message">Adjust search or filter.</span>
          </div>
        )}

        {visibleGroups.map((group) => {
          const unread = unreadCountForGroup(group, notifications);
          return (
            <div className="session-group" key={group.id}>
              <div
                className="session-group-header"
                onClick={() => {
                  selectGroup(group.id);
                  close();
                }}
                role="button"
                tabIndex={0}
                onKeyDown={(event) => {
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    selectGroup(group.id);
                    close();
                  }
                }}
              >
                <button
                  type="button"
                  className={`star-button ${group.primaryWorkspace.starred ? "star-button-on" : ""}`}
                  title={group.primaryWorkspace.starred ? "Unstar" : "Star"}
                  onClick={(event) => {
                    event.stopPropagation();
                    toggleStar(group.primaryWorkspace.index, !group.primaryWorkspace.starred);
                  }}
                >
                  <Star size={14} fill={group.primaryWorkspace.starred ? "currentColor" : "none"} aria-hidden="true" />
                </button>
                <span className="session-group-name">{group.displayName}</span>
                <UnreadBadge count={unread} />
              </div>

              {group.workspaces.map((workspace, offset) => {
                const id = workspaceID(workspace);
                const selected = selectedWorkspaceID === id;
                return (
                  <div
                    key={id}
                    className={`pane-row ${selected ? "pane-row-selected" : ""}`}
                    onClick={() => {
                      selectWorkspace(id);
                      close();
                    }}
                    role="button"
                    tabIndex={0}
                    onKeyDown={(event) => {
                      if (event.key === "Enter" || event.key === " ") {
                        event.preventDefault();
                        selectWorkspace(id);
                        close();
                      }
                    }}
                  >
                    <span className="pane-row-name">{paneLabel(group, workspace, offset)}</span>
                    <StateBadge needsYou={workspaceNeedsYou(workspace, notifications, feedItems)} />
                  </div>
                );
              })}
            </div>
          );
        })}
      </div>
      </aside>
    </>
  );
}
