import { abbreviatedPath } from "../../lib/workspaceDisplay";
import { useNewSessionStore } from "../../store/newSessionStore";

/**
 * Port of the iOS `SessionCreationProgressOverlay` (ServerSetupViews.swift):
 * a centered card over a dimmed background with two phases —
 * `creating` ("Starting New Session") and `switching` ("Opening New Session").
 * It clears when the created workspace is auto-selected (see
 * workspacesStore.applyStatus); iOS has no timeout or dismiss, neither does
 * this one.
 *
 * The modal flow enters the overlay at `switching` (the modal itself covers
 * the request); the `creating` phase is kept for parity with iOS's
 * quick-create path.
 */
export function SessionCreationProgressOverlay() {
  const phase = useNewSessionStore((state) => state.phase);
  const directoryPath = useNewSessionStore((state) => state.overlayDirectory);

  if (phase === "idle") return null;

  const creating = phase === "creating";
  const title = creating ? "Starting New Session" : "Opening New Session";

  return (
    <div className="creation-overlay" role="status" aria-live="polite" aria-label={title}>
      <div className="creation-overlay-card">
        <div className="spinner spinner-lg creation-overlay-spinner" aria-hidden />
        <h2 className="creation-overlay-title">{title}</h2>
        {creating ? (
          <p className="creation-overlay-message">
            Creating a shell session in{" "}
            <span className="creation-overlay-path">{abbreviatedPath(directoryPath ?? "", 3)}</span>.
            {" We'll switch you over when it's ready."}
          </p>
        ) : (
          <p className="creation-overlay-message">The session is ready. Switching you over now.</p>
        )}
      </div>
    </div>
  );
}
