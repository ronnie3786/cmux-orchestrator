import { X } from "lucide-react";
import { useNewSessionStore, type NewSessionMode } from "../../store/newSessionStore";
import { useEscapeLayer, useScrollLock } from "../../hooks/useOverlay";

/**
 * Port of the iOS `NewSessionView` (SettingsNewSessionViews.swift):
 * Claude/Shell segmented control, project path, shell-mode Name field,
 * Claude-mode JIRA URL + Branch (branch auto-fills from the JIRA key while
 * empty), optional prompt, create/creating/error states.
 *
 * Mounted at App level; visibility is driven by the store (opened from the
 * workspace detail actions menu).
 */
export function NewSessionModal() {
  const isOpen = useNewSessionStore((s) => s.isOpen);
  const mode = useNewSessionStore((s) => s.mode);
  const projectPath = useNewSessionStore((s) => s.projectPath);
  const branchName = useNewSessionStore((s) => s.branchName);
  const jiraUrl = useNewSessionStore((s) => s.jiraUrl);
  const prompt = useNewSessionStore((s) => s.prompt);
  const sessionName = useNewSessionStore((s) => s.sessionName);
  const error = useNewSessionStore((s) => s.error);
  const phase = useNewSessionStore((s) => s.phase);
  const { cancel, close, setMode, setProjectPath, setBranchName, setJiraUrl, setPrompt, setSessionName, submit } =
    useNewSessionStore();

  const creating = phase === "creating";

  // Escape cancels (blocked while the request is in flight, like Cancel).
  // The layer still consumes Esc while creating — it just does nothing with
  // the key, which also blocks lower layers.
  useEscapeLayer(
    () => {
      if (!creating) cancel();
    },
    isOpen,
  );
  useScrollLock(isOpen);

  if (!isOpen) return null;

  const canCreate = !creating && projectPath.trim().length > 0;

  return (
    <div
      className="dialog-backdrop"
      onMouseDown={(event) => {
        // Backdrop click cancels only when the click started on the backdrop.
        if (event.target === event.currentTarget && !creating) cancel();
      }}
    >
      <div className="dialog new-session-dialog" role="dialog" aria-modal="true" aria-label="New Session">
        <div className="dialog-title">
          <span>New Session</span>
          <button
            type="button"
            className="icon-button"
            onClick={() => close()}
            disabled={creating}
            aria-label="Close"
          >
            <X size={16} />
          </button>
        </div>

        <div className="segmented" role="tablist" aria-label="Session type">
          {(["claude", "shell"] as const).map((option: NewSessionMode) => (
            <button
              key={option}
              type="button"
              role="tab"
              aria-selected={mode === option}
              className={`segmented-option${mode === option ? " segmented-option-active" : ""}`}
              onClick={() => setMode(option)}
              disabled={creating}
            >
              {option === "claude" ? "Claude" : "Shell"}
            </button>
          ))}
        </div>

        <div className="dialog-body">
          <label className="field-label" htmlFor="new-session-path">
            Project path
          </label>
          <input
            id="new-session-path"
            className="dialog-input mono"
            value={projectPath}
            onChange={(event) => setProjectPath(event.target.value)}
            placeholder="~/Documents/Development/sample-app"
            disabled={creating}
            spellCheck={false}
            autoComplete="off"
          />

          {mode === "shell" ? (
            <>
              <label className="field-label" htmlFor="new-session-name">
                Name
              </label>
              <input
                id="new-session-name"
                className="dialog-input"
                value={sessionName}
                onChange={(event) => setSessionName(event.target.value)}
                placeholder="Shell"
                disabled={creating}
                spellCheck={false}
              />
            </>
          ) : (
            <>
              <div className="field-label field-label-section">Worktree</div>

              <label className="field-label" htmlFor="new-session-jira">
                JIRA URL
              </label>
              <input
                id="new-session-jira"
                className="dialog-input"
                value={jiraUrl}
                onChange={(event) => setJiraUrl(event.target.value)}
                placeholder="https://doximity.atlassian.net/browse/IOSDOX-123"
                disabled={creating}
                spellCheck={false}
                autoComplete="off"
              />

              <label className="field-label" htmlFor="new-session-branch">
                Branch
              </label>
              <input
                id="new-session-branch"
                className="dialog-input mono"
                value={branchName}
                onChange={(event) => setBranchName(event.target.value)}
                placeholder="IOSDOX-123"
                disabled={creating}
                spellCheck={false}
                autoComplete="off"
              />

              <label className="field-label" htmlFor="new-session-prompt">
                Prompt
              </label>
              <textarea
                id="new-session-prompt"
                className="dialog-input dialog-textarea"
                rows={5}
                value={prompt}
                onChange={(event) => setPrompt(event.target.value)}
                placeholder="Initial prompt (optional)"
                disabled={creating}
              />
            </>
          )}

          {error && (
            <p className="dialog-error" role="alert">
              {error}
            </p>
          )}
        </div>

        <div className="dialog-actions">
          <button type="button" className="btn btn-secondary" onClick={() => cancel()} disabled={creating}>
            Cancel
          </button>
          <button
            type="button"
            className="btn btn-primary"
            onClick={() => void submit()}
            disabled={!canCreate}
          >
            {creating ? (
              <span className="btn-busy">
                <span className="spinner" aria-hidden /> Creating…
              </span>
            ) : (
              "Create"
            )}
          </button>
        </div>
      </div>
    </div>
  );
}
