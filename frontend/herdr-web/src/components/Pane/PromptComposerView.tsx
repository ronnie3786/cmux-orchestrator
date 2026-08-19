/**
 * Command Lens (P9-run-A) — web port of the shell/agent side of the iOS
 * `PromptComposerView` for the selected NON-Pi pane (Pi panes render
 * PiChatPane with their own PiComposer, so this dock never sees them):
 *
 *  - status-aware placeholder (doc 01 §6): shell pane →
 *    "run or type into this shell"; agent pane → "message <agent>". The
 *    agent string is server-owned lowercase (live check: "pi", "opencode")
 *    and rendered as-is, mirroring iOS `displayAgentName` (no case
 *    transformation in the Swift source).
 *  - agent-aware send (doc 01 §4.3): shell → POST /run {command}; agent →
 *    POST /prompt {text} + "Sent to <agent>" toast.
 *  - connection gate: not Live/Demo → send shows
 *    "Reconnect before controlling Herdr" and fires nothing.
 *  - key deck (8 keys) above the composer; aux chip row below (run-B modals).
 *
 * The pure helpers (composerAgentName / composerPlaceholder /
 * composerDispatch / canSend) are exported for unit tests.
 */
import { useEffect, useRef, useState } from "react";
import { panePrompt, paneRun, paneSendKeys } from "../../api/paneCommands";
import { useConnectionStore, type ConnectionStatus } from "../../store/connectionStore";
import { showToast } from "../../lib/toast";
import type { Pane } from "../../types/herdr";
import { ComposerAuxBar, type AuxActionName } from "./ComposerAuxBar";
import { TerminalKeyDeck, type PaneKey } from "./TerminalKeyDeck";
import "./pane.css";

type ComposerPane = Pick<Pane, "agent" | "agent_status">;

/** The pane's agent name for composing, or null when it is a shell pane. */
export function composerAgentName(pane: ComposerPane): string | null {
  if (pane.agent_status === "unknown") {
    return null;
  }
  return pane.agent !== undefined && pane.agent !== "" ? pane.agent : null;
}

export function composerPlaceholder(pane: ComposerPane): string {
  const agent = composerAgentName(pane);
  return agent === null ? "run or type into this shell" : `message ${agent}`;
}

export type ComposerDispatch =
  | { kind: "run"; payload: { command: string } }
  | { kind: "prompt"; payload: { text: string } };

export function composerDispatch(pane: ComposerPane, text: string): ComposerDispatch {
  return composerAgentName(pane) === null
    ? { kind: "run", payload: { command: text } }
    : { kind: "prompt", payload: { text } };
}

/** Send is gated to Live/Demo (doc 01 §6 connection vocabulary). */
export function canSend(connection: ConnectionStatus): boolean {
  return connection === "Live" || connection === "Demo";
}

export interface PromptComposerViewProps {
  pane: Pane;
  /** Placeholder hook for the run-B aux modals ("attach" / "@ file" / "jira"). */
  onAction?: (name: AuxActionName) => void;
}

export function PromptComposerView({ pane, onAction }: PromptComposerViewProps) {
  const [draft, setDraft] = useState("");
  const [sending, setSending] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const status = useConnectionStore((state) => state.status);

  // Textarea auto-grows 1–3 lines (same technique as PiComposer).
  useEffect(() => {
    const el = textareaRef.current;
    if (el === null) {
      return;
    }
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 3 * lineHeight(el))}px`;
  }, [draft]);

  const send = async (): Promise<void> => {
    const text = draft.trim();
    if (text === "" || sending) {
      return;
    }
    if (!canSend(useConnectionStore.getState().status)) {
      showToast("Reconnect before controlling Herdr");
      return;
    }
    setSending(true);
    try {
      const dispatch = composerDispatch(pane, text);
      if (dispatch.kind === "run") {
        await paneRun(pane.pane_id, text);
      } else {
        await panePrompt(pane.pane_id, text);
        const agent = composerAgentName(pane);
        if (agent !== null) {
          showToast(`Sent to ${agent}`);
        }
      }
      setDraft("");
    } catch (error) {
      showToast(error instanceof Error ? error.message : "Send failed");
    } finally {
      setSending(false);
    }
  };

  const sendKey = (key: PaneKey): void => {
    if (!canSend(useConnectionStore.getState().status)) {
      return;
    }
    void paneSendKeys(pane.pane_id, [key]).catch((error: unknown) => {
      showToast(error instanceof Error ? error.message : "Send failed");
    });
  };

  return (
    <div className="hz-pane-lens">
      <TerminalKeyDeck enabled={canSend(status)} onKey={sendKey} />
      <div className="hz-pane-composer">
        <textarea
          ref={textareaRef}
          className="hz-pane-composer-input"
          rows={1}
          placeholder={composerPlaceholder(pane)}
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !event.shiftKey) {
              event.preventDefault();
              void send();
            }
          }}
        />
        <button
          type="button"
          className="hz-pane-send"
          disabled={sending || draft.trim() === ""}
          onClick={() => void send()}
        >
          Send
        </button>
      </div>
      <ComposerAuxBar onAction={onAction ?? (() => undefined)} />
    </div>
  );
}

function lineHeight(el: HTMLTextAreaElement): number {
  const value = Number.parseFloat(getComputedStyle(el).lineHeight);
  return Number.isFinite(value) && value > 0 ? value : 18;
}
