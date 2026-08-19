import { useEffect, useMemo, useState } from "react";
import { ChevronDown, ChevronRight, Plus, Search, Settings } from "lucide-react";
import { useWorkspacesStore } from "../../store/workspacesStore";
import {
  compactStatus,
  groupMatchesSearch,
  groups,
  type ChatRow,
} from "../../lib/workspaceGroups";
import { canControlNow } from "../../store/connectionStore";
import { showToast } from "../../lib/toast";
import type { Pane } from "../../types/herdr";
import { useEscapeLayer, useScrollLock } from "../../hooks/useOverlay";
import { PaneMenuButton } from "./PaneMenu";
import { CreateWorkspaceModal } from "../Workspace/CreateWorkspaceModal";
import "./sidebar.css";

const COLLAPSED_STORAGE_KEY = "herdr.web.sidebar.collapsedWorkspaces";

function loadCollapsed(): Set<string> {
  try {
    const raw = localStorage.getItem(COLLAPSED_STORAGE_KEY);
    if (!raw) return new Set();
    const parsed: unknown = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      return new Set(parsed.filter((value): value is string => typeof value === "string"));
    }
  } catch {
    // Corrupt storage — start uncollapsed.
  }
  return new Set();
}

function ChatRowView({
  chat,
  pane,
  selected,
  onSelect,
}: {
  chat: ChatRow;
  pane: Pane;
  selected: boolean;
  onSelect: () => void;
}) {
  return (
    <div
      className={`hz-chat-row${selected ? " hz-chat-row-selected" : ""}`}
      role="button"
      tabIndex={0}
      onClick={onSelect}
      onKeyDown={(event) => {
        if (event.target !== event.currentTarget) return;
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onSelect();
        }
      }}
    >
      <span className={`hz-dot hz-dot-${chat.status}`} aria-hidden />
      <span className="hz-chat-title">{chat.title}</span>
      <span className="hz-chat-status">{compactStatus(chat.status)}</span>
      <PaneMenuButton pane={pane} onNavigate={onSelect} />
    </div>
  );
}

interface SidebarProps {
  /** Overlay drawer state (used below the 900 px breakpoint only). */
  open: boolean;
  onClose: () => void;
  /** Opens the settings modal (web stand-in for the iOS Settings tab). */
  onOpenSettings: () => void;
}

/**
 * The "chats" navigator (iOS HerdrSidebarView parity): brand "herdr" +
 * "switch", "chats" section with a "filter chats" input, "new workspace",
 * the workspace → tab → chat tree (collapsed set persisted to localStorage
 * and honored only when unfiltered, iOS SidebarTree), and a "N total shown"
 * footer. Persistent left rail at ≥900 px; overlay drawer with backdrop
 * below (Esc / backdrop / "Close navigator" close it).
 */
export function Sidebar({ open, onClose, onOpenSettings }: SidebarProps) {
  const data = useWorkspacesStore((state) => state.data);
  const selectedWorkspaceId = useWorkspacesStore((state) => state.selectedWorkspaceId);
  const selectedPaneId = useWorkspacesStore((state) => state.selectedPaneId);

  const [query, setQuery] = useState("");
  const [collapsed, setCollapsed] = useState<Set<string>>(loadCollapsed);
  const [createOpen, setCreateOpen] = useState(false);

  // Drawer hygiene (Phase-1 overlay pattern): Esc closes the drawer, body
  // scroll locks while it is open.
  useEscapeLayer(onClose, open);
  useScrollLock(open);

  // Persist the collapsed set.
  useEffect(() => {
    try {
      localStorage.setItem(COLLAPSED_STORAGE_KEY, JSON.stringify([...collapsed]));
    } catch {
      // Storage unavailable — collapse state just won't persist.
    }
  }, [collapsed]);

  const all = useMemo(() => groups(data?.workspaces ?? []), [data]);
  // Raw Pane objects by id (ChatRow only carries display fields).
  const panesById = useMemo(() => {
    const map = new Map<string, Pane>();
    for (const workspace of data?.workspaces ?? []) {
      for (const pane of workspace.panes) map.set(pane.pane_id, pane);
    }
    return map;
  }, [data]);
  const filtering = query.trim().length > 0;
  const visible = useMemo(
    () => (filtering ? all.filter((group) => groupMatchesSearch(group, query)) : all),
    [all, filtering, query],
  );

  const toggleCollapsed = (workspaceId: string) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(workspaceId)) {
        next.delete(workspaceId);
      } else {
        next.add(workspaceId);
      }
      return next;
    });
  };

  const selectWorkspace = (workspaceId: string, paneId: string | null) => {
    useWorkspacesStore.getState().repairSelection(workspaceId, paneId);
  };

  return (
    <>
      {open ? <div className="hz-sidebar-backdrop" onClick={onClose} aria-hidden /> : null}
      <aside className={`hz-sidebar${open ? " hz-sidebar-open" : ""}`} aria-label="chats">
        <header className="hz-sidebar-header">
          <span className="hz-sidebar-brand">herdr</span>
          <button type="button" className="hz-sidebar-switch" onClick={onClose}>
            switch
          </button>
          <button
            type="button"
            className="hz-sidebar-settings"
            onClick={onOpenSettings}
            aria-label="Settings"
          >
            <Settings size={15} aria-hidden />
          </button>
          {open ? (
            <button type="button" className="hz-sidebar-close" onClick={onClose}>
              Close navigator
            </button>
          ) : null}
        </header>

        <div className="hz-sidebar-new">
          <button
            type="button"
            className="hz-sidebar-new-button"
            onClick={() => {
              if (!canControlNow()) {
                showToast("Reconnect before controlling Herdr");
                return;
              }
              setCreateOpen(true);
            }}
          >
            <Plus size={14} aria-hidden />
            <span>new workspace</span>
          </button>
        </div>
        {createOpen ? <CreateWorkspaceModal onClose={() => setCreateOpen(false)} /> : null}

        <div className="hz-sidebar-section">
          <span className="hz-sidebar-section-label">chats</span>
          <label className="hz-sidebar-search">
            <Search size={14} className="hz-sidebar-search-icon" aria-hidden="true" />
            <input
              className="hz-sidebar-search-input"
              type="text"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="filter chats"
              aria-label="filter chats"
              autoComplete="off"
              autoCapitalize="off"
              spellCheck={false}
            />
          </label>
        </div>

        <div className="hz-sidebar-tree">
          {all.length === 0 ? (
            <div className="hz-sidebar-empty">No Herdr workspaces</div>
          ) : null}
          {all.length > 0 && visible.length === 0 ? (
            <div className="hz-sidebar-empty">No Herdr workspaces</div>
          ) : null}

          {visible.map((group) => {
            const isCollapsed = !filtering && collapsed.has(group.workspaceId);
            return (
              <div className="hz-project" key={group.workspaceId}>
                <div
                  className={`hz-project-row${
                    selectedWorkspaceId === group.workspaceId ? " hz-project-row-selected" : ""
                  }`}
                  role="button"
                  tabIndex={0}
                  onClick={() => selectWorkspace(group.workspaceId, null)}
                  onKeyDown={(event) => {
                    if (event.key === "Enter" || event.key === " ") {
                      event.preventDefault();
                      selectWorkspace(group.workspaceId, null);
                    }
                  }}
                >
                  <button
                    type="button"
                    className="hz-project-chevron"
                    aria-label={isCollapsed ? "Expand workspace" : "Collapse workspace"}
                    onClick={(event) => {
                      event.stopPropagation();
                      toggleCollapsed(group.workspaceId);
                    }}
                  >
                    {isCollapsed ? (
                      <ChevronRight size={14} aria-hidden />
                    ) : (
                      <ChevronDown size={14} aria-hidden />
                    )}
                  </button>
                  <span className={`hz-dot hz-dot-${group.agentStatus}`} aria-hidden />
                  <span className="hz-project-label">{group.label}</span>
                  {group.focused ? <span className="hz-project-active">active</span> : null}
                  {group.attentionCount > 0 ? (
                    <span className="hz-project-attention">{group.attentionCount}</span>
                  ) : null}
                </div>

                {!isCollapsed ? (
                  <div className="hz-project-body">
                    {group.paneCount === 0 ? (
                      <div className="hz-project-empty">no panes yet</div>
                    ) : null}
                    {group.tabSections.map((section) => (
                      <div key={section.tab.tab_id}>
                        <div className="hz-tab-row">
                          <span className="hz-tab-label">{section.tab.label}</span>
                          <span className="hz-tab-count">{section.tab.pane_count}</span>
                        </div>
                        {section.chats.map((chat) => (
                          <ChatRowView
                            key={chat.paneId}
                            chat={chat}
                            pane={panesById.get(chat.paneId)!}
                            selected={
                              selectedWorkspaceId === group.workspaceId && selectedPaneId === chat.paneId
                            }
                            onSelect={() => selectWorkspace(group.workspaceId, chat.paneId)}
                          />
                        ))}
                      </div>
                    ))}
                    {group.looseChats.map((chat) => (
                      <ChatRowView
                        key={chat.paneId}
                        chat={chat}
                        pane={panesById.get(chat.paneId)!}
                        selected={
                          selectedWorkspaceId === group.workspaceId && selectedPaneId === chat.paneId
                        }
                        onSelect={() => selectWorkspace(group.workspaceId, chat.paneId)}
                      />
                    ))}
                  </div>
                ) : null}
              </div>
            );
          })}
        </div>

        <footer className="hz-sidebar-footer">{visible.length} total shown</footer>
      </aside>
    </>
  );
}
