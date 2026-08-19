import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { ChevronLeft, MoreHorizontal } from "lucide-react";
import { interruptAgent, renamePane, deletePane, startAgent } from "../../api/mutations";
import { canControlNow, useConnectionStore } from "../../store/connectionStore";
import { usePaneModeStore, type PaneMode } from "../../store/paneModeStore";
import { chatDisplayName } from "../../lib/workspaceGroups";
import { showToast } from "../../lib/toast";
import type { Pane } from "../../types/herdr";
import { usePopover } from "../../hooks/usePopover";
import "./pane-menu.css";

// --- menu model (pure — unit-tested in PaneMenu.test.ts) ----------------------

/**
 * The iOS start-agent picker (doc 01 §3 PaneActionsMenu: "Start agent
 * (only when agentStatus == .unknown: Codex / Claude / OpenCode)"; §6
 * byte-exact: `Start agent` → `Codex`/`Claude`/`OpenCode`). `agent` is the
 * server-side start-agent kind (doc 02 §2).
 */
export interface AgentPickerOption {
  label: string;
  agent: "codex" | "claude" | "opencode";
}

export const AGENT_PICKER: readonly AgentPickerOption[] = [
  { label: "Codex", agent: "codex" },
  { label: "Claude", agent: "claude" },
  { label: "OpenCode", agent: "opencode" },
];

export type PaneMenuItem =
  | { id: "viewChat"; label: string; enabled: boolean; checked: boolean }
  | { id: "viewTerminal"; label: string; enabled: boolean; checked: boolean }
  | { id: "interrupt"; label: string; enabled: boolean }
  | { id: "startAgent"; label: string; enabled: boolean }
  | { id: "rename"; label: string; enabled: boolean }
  | { id: "close"; label: string; enabled: boolean };

export interface PaneMenuOptions {
  /** Demo mode: every mutating item is disabled (mode toggle stays live —
   * it is local state). */
  demo: boolean;
  /** Effective mode of a Pi pane; "chat" is the auto default. */
  mode?: PaneMode;
}

const LABELS = {
  chat: "Chat",
  terminal: "Terminal",
  interrupt: "Interrupt",
  startAgent: "Start agent",
  rename: "Rename pane",
  close: "Close pane",
} as const;

/**
 * Visibility rules (mirroring doc 01 §3 PaneActionsMenu / sidebar menu):
 *  - Chat/Terminal mode toggle: only for Pi-capable panes (pi_semantic
 *    available && protocol v1).
 *  - Interrupt: agent panes (agent_status working or a detected agent).
 *  - Start agent: shell/unknown panes only.
 *  - Rename pane / Close pane: always.
 * Demo mode disables every mutating item; the mode toggle is always
 * enabled (local state only).
 */
export function menuItemsFor(pane: Pane, options: PaneMenuOptions): PaneMenuItem[] {
  const items: PaneMenuItem[] = [];
  const mode = options.mode ?? "chat";
  const piSemantic = pane.pi_semantic;
  const supportsPiChat =
    piSemantic !== undefined && piSemantic.available && piSemantic.protocol_version === 1;

  if (supportsPiChat) {
    items.push({ id: "viewChat", label: LABELS.chat, enabled: true, checked: mode === "chat" });
    items.push({
      id: "viewTerminal",
      label: LABELS.terminal,
      enabled: true,
      checked: mode === "terminal",
    });
  }
  if (pane.agent_status === "working" || pane.agent !== undefined) {
    items.push({ id: "interrupt", label: LABELS.interrupt, enabled: !options.demo });
  }
  if (pane.agent_status === "unknown") {
    items.push({ id: "startAgent", label: LABELS.startAgent, enabled: !options.demo });
  }
  items.push({ id: "rename", label: LABELS.rename, enabled: !options.demo });
  items.push({ id: "close", label: LABELS.close, enabled: !options.demo });
  return items;
}

// --- UI ------------------------------------------------------------------------

type Stage = "menu" | "picker" | "rename" | "confirm";

interface PaneMenuButtonProps {
  pane: Pane;
  /** Called after a mode selection (or any action) to select the pane. */
  onNavigate?: () => void;
}

function errorMessage(error: unknown): string {
  return error instanceof Error && error.message ? error.message : "Request failed";
}

/**
 * The ⋯ pane menu (iOS PaneActionsMenu / sidebar per-pane menu parity).
 * Popover stages: menu → picker (start agent) / rename (inline input) /
 * confirm (close pane). Strings byte-exact per doc 01 §6: "Interrupt",
 * "Rename pane", "Pane name", "Close pane", "Start agent" → Codex/Claude/
 * OpenCode, confirm "Close this pane?" + "This stops the process running in
 * <title>.", toasts "Pane renamed" / "Pane closed" / "<Kind> started" /
 * "Reconnect before controlling Herdr".
 */
export function PaneMenuButton({ pane, onNavigate }: PaneMenuButtonProps) {
  const popover = usePopover();
  const [stage, setStage] = useState<Stage>("menu");
  const [draft, setDraft] = useState("");

  // Clicking outside closes the panel without going through close() —
  // reset any sub-stage so the next open starts at the menu.
  useEffect(() => {
    if (!popover.open) setStage("menu");
  }, [popover.open]);

  const mode = usePaneModeStore((state) => state.modeFor(pane));
  const demo = useConnectionStore((state) => state.status) === "Demo";
  const items = menuItemsFor(pane, { demo, mode: mode ?? undefined });

  const close = () => {
    popover.close();
    setStage("menu");
    setDraft("");
  };

  // Mutating actions mirror P9's composer gate (PromptComposerView): any
  // control attempt that isn't Live fires "Reconnect before controlling
  // Herdr" and nothing else. The mode toggle is local state and never
  // hits the server, so it is ungated.
  const gate = (): boolean => {
    if (canControlNow()) return true;
    showToast("Reconnect before controlling Herdr");
    return false;
  }

  const selectMode = (next: PaneMode) => {
    usePaneModeStore.getState().setMode(pane.workspace_id, pane.pane_id, next);
    onNavigate?.();
    close();
  };

  const runInterrupt = async () => {
    close();
    try {
      await interruptAgent(pane.pane_id);
    } catch (error) {
      showToast(errorMessage(error));
    }
  };

  const runStartAgent = async (agent: (typeof AGENT_PICKER)[number]) => {
    close();
    try {
      await startAgent(pane.pane_id, agent.agent);
      showToast(`${agent.label} started`);
    } catch (error) {
      showToast(errorMessage(error));
    }
  };

  const runRename = async () => {
    const label = draft.trim();
    if (!label) {
      close();
      return;
    }
    close();
    try {
      await renamePane(pane.pane_id, label);
      showToast("Pane renamed");
      // No manual refetch — snapshot.updated arms the debounced /workspaces
      // refetch (eventStream).
    } catch (error) {
      showToast(errorMessage(error));
    }
  };

  const runDelete = async () => {
    close();
    try {
      await deletePane(pane.pane_id);
      showToast("Pane closed");
    } catch (error) {
      showToast(errorMessage(error));
    }
  };

  const clickItem = (item: PaneMenuItem) => {
    if (item.id === "viewChat" || item.id === "viewTerminal") {
      selectMode(item.id === "viewChat" ? "chat" : "terminal");
      return;
    }
    if (!item.enabled || !gate()) return;
    switch (item.id) {
      case "interrupt":
        void runInterrupt();
        break;
      case "startAgent":
        setStage("picker");
        break;
      case "rename":
        setDraft((pane.label ?? "").trim());
        setStage("rename");
        break;
      case "close":
        setStage("confirm");
        break;
    }
  };

  return (
    <>
      <button
        type="button"
        className="hz-pane-menu-toggle"
        aria-label="Pane actions"
        aria-expanded={popover.open}
        onClick={(event) => {
          event.stopPropagation();
          popover.toggle(event.currentTarget);
        }}
      >
        <MoreHorizontal size={13} aria-hidden />
      </button>
      {popover.open && popover.style !== null
        ? createPortal(
            <div
              ref={popover.panelRef}
              className="hz-popover"
              style={popover.style}
              role="menu"
              onClick={(event) => event.stopPropagation()}
            >
              {stage === "menu" ? (
                <MenuStage items={items} onClick={clickItem} />
              ) : null}
              {stage === "picker" ? (
                <PickerStage onPick={runStartAgent} onBack={() => setStage("menu")} />
              ) : null}
              {stage === "rename" ? (
                <RenameStage
                  value={draft}
                  onChange={setDraft}
                  onSubmit={runRename}
                  onCancel={close}
                />
              ) : null}
              {stage === "confirm" ? (
                <ConfirmStage
                  title="Close this pane?"
                  message={`This stops the process running in ${chatDisplayName(pane)}.`}
                  confirmLabel="Close pane"
                  onConfirm={runDelete}
                  onCancel={() => setStage("menu")}
                />
              ) : null}
            </div>,
            document.body,
          )
        : null}
    </>
  );
}

// --- stages ------------------------------------------------------------------

function MenuStage({
  items,
  onClick,
}: {
  items: PaneMenuItem[];
  onClick: (item: PaneMenuItem) => void;
}) {
  return (
    <>
      {items.map((item) => (
        <button
          key={item.id}
          type="button"
          role="menuitem"
          className={`hz-menu-item${
            item.id === "close" ? " hz-menu-item-destructive" : ""
          }${item.enabled ? "" : " hz-menu-item-disabled"}`}
          onClick={() => onClick(item)}
        >
          {"checked" in item ? (
            <span className="hz-menu-item-check" aria-hidden>
              {item.checked ? "✓" : ""}
            </span>
          ) : (
            <span className="hz-menu-item-check" aria-hidden />
          )}
          <span>{item.label}</span>
        </button>
      ))}
    </>
  );
}

function PickerStage({
  onPick,
  onBack,
}: {
  onPick: (option: (typeof AGENT_PICKER)[number]) => void;
  onBack: () => void;
}) {
  return (
    <>
      <button type="button" className="hz-menu-back" onClick={onBack}>
        <ChevronLeft size={13} aria-hidden />
        Start agent
      </button>
      {AGENT_PICKER.map((option) => (
        <button
          key={option.agent}
          type="button"
          role="menuitem"
          className="hz-menu-item"
          onClick={() => onPick(option)}
        >
          <span className="hz-menu-item-check" aria-hidden />
          <span>{option.label}</span>
        </button>
      ))}
    </>
  );
}

function RenameStage({
  value,
  onChange,
  onSubmit,
  onCancel,
}: {
  value: string;
  onChange: (value: string) => void;
  onSubmit: () => void;
  onCancel: () => void;
}) {
  return (
    <>
      <div className="hz-popover-label">Pane name</div>
      <input
        className="hz-popover-input"
        type="text"
        value={value}
        placeholder="Pane name"
        aria-label="Pane name"
        autoFocus
        onChange={(event) => onChange(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Enter") onSubmit();
        }}
      />
      <div className="hz-popover-actions">
        <button type="button" className="hz-popover-button" onClick={onCancel}>
          Cancel
        </button>
        <button
          type="button"
          className="hz-popover-button hz-popover-button-primary"
          disabled={!value.trim()}
          onClick={onSubmit}
        >
          Rename
        </button>
      </div>
    </>
  );
}

function ConfirmStage({
  title,
  message,
  confirmLabel,
  onConfirm,
  onCancel,
}: {
  title: string;
  message: string;
  confirmLabel: string;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  return (
    <>
      <div className="hz-popover-label">{title}</div>
      <div className="hz-popover-message">{message}</div>
      <div className="hz-popover-actions">
        <button type="button" className="hz-popover-button" onClick={onCancel}>
          Cancel
        </button>
        <button
          type="button"
          className="hz-popover-button hz-popover-button-destructive"
          onClick={onConfirm}
        >
          {confirmLabel}
        </button>
      </div>
    </>
  );
}
