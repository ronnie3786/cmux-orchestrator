/**
 * One pending-interaction card (P8-run-B) — web port of
 * `herdr-harness-ios/Views/Pane/PiInteractionCardView.swift`:
 *
 *  - select   → one button per option (click → respond {value})
 *  - confirm  → "No" / "Yes" (respond {confirmed: false/true})
 *  - input    → text field + "Submit" / "Cancel" (respond {value} / {cancelled})
 *  - editor   → rendered like input (Swift treats editor identically)
 *  - unknown  → no card; PiChatView keeps the "Pi needs your input"
 *    indicator row as the fallback
 *
 * The store removes the interaction on a successful respond (reducer
 * `removeInteraction`); on failure the server error string (store
 * `lastError`, e.g. the 501 message) is shown as a muted notice line.
 */
import { useState } from "react";
import { piConnectionIsConnected } from "../../pi/types";
import {
  PI_INTERACTION_CANCELLED,
  piInteractionConfirmation,
  piInteractionSelection,
  piInteractionText,
  type PiInteractionResponseBody,
  type PiPendingInteraction,
} from "../../pi/types";
import { usePiStore } from "../../store/piStore";

export interface InteractionCardProps {
  interaction: PiPendingInteraction;
}

export function InteractionCard({ interaction }: InteractionCardProps) {
  const bridgeConnected = usePiStore((state) => state.bridgeConnected);
  const connection = usePiStore((state) => state.connection);
  const [text, setText] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isConnected = bridgeConnected && piConnectionIsConnected(connection);

  const submit = async (body: PiInteractionResponseBody): Promise<void> => {
    if (isSubmitting) return;
    setIsSubmitting(true);
    setError(null);
    try {
      const succeeded = await usePiStore.getState().respond(interaction.id, body);
      if (!succeeded) {
        const lastError = usePiStore.getState().lastError;
        if (lastError !== null) setError(lastError);
      }
    } finally {
      setIsSubmitting(false);
    }
  };

  const trimmed = text.trim();
  const disabled = !isConnected || isSubmitting;

  return (
    <div className="hz-pi-interaction-card" data-pi-interaction={interaction.id}>
      <p className="hz-pi-interaction-title">{interaction.title}</p>
      {interaction.message !== null && (
        <p className="hz-pi-interaction-message">{interaction.message}</p>
      )}
      <div className="hz-pi-interaction-controls">
        {interaction.kind === "select" &&
          interaction.options.map((option) => (
            <button
              key={option}
              type="button"
              className="hz-pi-interaction-option"
              disabled={disabled}
              onClick={() => void submit(piInteractionSelection(option))}
            >
              {option}
            </button>
          ))}
        {interaction.kind === "confirm" && (
          <>
            <button
              type="button"
              className="hz-pi-interaction-option"
              disabled={disabled}
              onClick={() => void submit(piInteractionConfirmation(false))}
            >
              No
            </button>
            <button
              type="button"
              className="hz-pi-interaction-option hz-pi-interaction-primary"
              disabled={disabled}
              onClick={() => void submit(piInteractionConfirmation(true))}
            >
              Yes
            </button>
          </>
        )}
        {(interaction.kind === "input" || interaction.kind === "editor") && (
          <>
            <textarea
              className="hz-pi-interaction-text"
              rows={1}
              placeholder={interaction.placeholder ?? "Response"}
              value={text}
              disabled={disabled}
              onChange={(event) => setText(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter" && !event.shiftKey) {
                  event.preventDefault();
                  if (!disabled && trimmed !== "") void submit(piInteractionText(trimmed));
                }
              }}
            />
            <button
              type="button"
              className="hz-pi-interaction-primary"
              disabled={disabled || trimmed === ""}
              onClick={() => void submit(piInteractionText(trimmed))}
            >
              Submit
            </button>
            <button
              type="button"
              className="hz-pi-interaction-cancel"
              disabled={disabled}
              onClick={() => void submit(PI_INTERACTION_CANCELLED)}
            >
              Cancel
            </button>
          </>
        )}
      </div>
      {error !== null && <p className="hz-pi-interaction-error">{error}</p>}
    </div>
  );
}
