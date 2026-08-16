import { useCallback, useEffect, useRef, useState } from "react";
import { Send } from "lucide-react";
import { sendTextOrKey } from "../../api/endpoints";
import type { HarnessKey } from "../../api/types";
import { useDraftStore } from "../../store/draftStore";

interface MinimalInputRowProps {
  /** cmux index of the selected session; null disables the row. */
  index: number | null;
}

/**
 * Quick keys are limited to the server's /api/send whitelist. The button
 * labels are display-only; `key` is what gets sent.
 *
 * The text field is bound to the per-workspace draft (draftStore, iOS
 * `detailDraft` parity): drafts survive tab switches and reloads, appended
 * prompt blocks (diff-line comments, PR threads) land here, and the field
 * focuses whenever the Git tab raises a focus request. Phase 4 replaces the
 * local `text` state with the full input bar on top of this plumbing.
 */
const QUICK_KEYS: Array<{ key: HarnessKey; label: string; title: string }> = [
  { key: "enter", label: "Enter", title: "Send Enter" },
  { key: "up", label: "↑", title: "Send Up arrow" },
  { key: "down", label: "↓", title: "Send Down arrow" },
  { key: "tab", label: "Tab", title: "Send Tab" },
  { key: "escape", label: "Esc", title: "Send Escape" },
];

export function MinimalInputRow({ index }: MinimalInputRowProps) {
  const draft = useDraftStore((state) => state.activeDraft);
  const setDraft = useDraftStore((state) => state.setDraft);
  const focusRequest = useDraftStore((state) => state.focusRequest);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  // iOS `detailInputFocusHandled`: the Git tab (diff-line comments, PR
  // threads) bumps the request; the input row focuses and marks it handled.
  useEffect(() => {
    if (focusRequest === 0) return;
    inputRef.current?.focus();
    useDraftStore.getState().markFocusHandled(focusRequest);
  }, [focusRequest]);

  const disabled = index === null || busy;

  const send = useCallback(
    async (payload: { text?: string; key?: HarnessKey }) => {
      if (index === null) return;
      setBusy(true);
      setError(null);
      try {
        // iOS sendTextEffect parity: input-bar text executes in the terminal
        // (iOS sends `message + "\n"`). Quick keys are unaffected.
        await sendTextOrKey({
          index,
          ...payload,
          ...(payload.text ? { text: payload.text + "\n" } : {}),
        });
        if (payload.text) {
          // iOS sends the draft then clears it (persistDetailDraft removes the
          // stored entry for an empty draft).
          useDraftStore.getState().clearDraft();
        }
        inputRef.current?.focus();
      } catch (err) {
        setError(err instanceof Error ? err.message : "Send failed");
      } finally {
        setBusy(false);
      }
    },
    [index],
  );

  const sendKey = useCallback(
    (key: HarnessKey) => {
      void send({ key });
    },
    [send],
  );

  return (
    <div className="input-row">
      <input
        ref={inputRef}
        className="input-row-field"
        type="text"
        placeholder={index === null ? "Select a session" : "Type a message…"}
        value={draft}
        disabled={disabled}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key !== "Enter") return;
          e.preventDefault();
          if (draft.trim().length > 0) {
            void send({ text: draft });
          } else {
            sendKey("enter");
          }
        }}
        aria-label="Send text to the session"
      />
      <div className="input-row-keys" role="group" aria-label="Send a key to the session">
        {QUICK_KEYS.map(({ key, label, title }) => (
          <button
            key={key}
            type="button"
            className="quick-key"
            title={title}
            disabled={disabled}
            onClick={() => sendKey(key)}
          >
            {label}
          </button>
        ))}
      </div>
      <button
        type="button"
        className="input-row-send"
        disabled={disabled || draft.trim().length === 0}
        onClick={() => void send({ text: draft })}
        aria-label="Send message"
      >
        <Send size={14} />
      </button>
      {error ? (
        <div className="input-row-error" title={error}>
          {error}
        </div>
      ) : null}
    </div>
  );
}
