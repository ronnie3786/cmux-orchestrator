import { useCallback, useRef, useState } from "react";
import { Send } from "lucide-react";
import { sendTextOrKey } from "../../api/endpoints";
import type { HarnessKey } from "../../api/types";

interface MinimalInputRowProps {
  /** cmux index of the selected session; null disables the row. */
  index: number | null;
}

/**
 * Quick keys are limited to the server's /api/send whitelist. The button
 * labels are display-only; `key` is what gets sent.
 */
const QUICK_KEYS: Array<{ key: HarnessKey; label: string; title: string }> = [
  { key: "enter", label: "Enter", title: "Send Enter" },
  { key: "up", label: "↑", title: "Send Up arrow" },
  { key: "down", label: "↓", title: "Send Down arrow" },
  { key: "tab", label: "Tab", title: "Send Tab" },
  { key: "escape", label: "Esc", title: "Send Escape" },
];

export function MinimalInputRow({ index }: MinimalInputRowProps) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const disabled = index === null || busy;

  const send = useCallback(
    async (payload: { text?: string; key?: HarnessKey }) => {
      if (index === null) return;
      setBusy(true);
      setError(null);
      try {
        await sendTextOrKey({ index, ...payload });
        if (payload.text) {
          setText("");
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
        value={text}
        disabled={disabled}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key !== "Enter") return;
          e.preventDefault();
          if (text.trim().length > 0) {
            void send({ text });
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
        disabled={disabled || text.trim().length === 0}
        onClick={() => void send({ text })}
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
