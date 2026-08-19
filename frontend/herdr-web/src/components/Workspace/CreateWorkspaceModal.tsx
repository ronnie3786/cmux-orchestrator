import { useState, type FormEvent } from "react";
import { createWorkspace, workspaceIdFromResult } from "../../api/mutations";
import { canControlNow } from "../../store/connectionStore";
import { useWorkspacesStore } from "../../store/workspacesStore";
import { setHashRoute } from "../../lib/hashRoute";
import { showToast } from "../../lib/toast";
import { useEscapeLayer, useScrollLock } from "../../hooks/useOverlay";
import "../Sidebar/pane-menu.css";
import "./workspace.css";

interface CreateWorkspaceModalProps {
  onClose: () => void;
}

function errorMessage(error: unknown): string {
  return error instanceof Error && error.message ? error.message : "Request failed";
}

/**
 * New-workspace sheet (iOS CreateWorkspaceView parity, doc 01 §3): Name +
 * "Folder path" fields, the info label, Cancel/Create. Creates via
 * POST /api/v1/workspaces `{label, cwd}` (doc 02 §2: `{cwd?, label?}`),
 * selects the new workspace (`#ws=<id>`), toasts "Workspace created".
 * Gated to Live connections (P9 composer pattern).
 */
export function CreateWorkspaceModal({ onClose }: CreateWorkspaceModalProps) {
  const [name, setName] = useState("");
  const [folder, setFolder] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEscapeLayer(onClose);
  useScrollLock(true);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (submitting) return;
    if (!canControlNow()) {
      showToast("Reconnect before controlling Herdr");
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const result = await createWorkspace({
        label: name.trim(),
        cwd: folder.trim() || undefined,
      });
      showToast("Workspace created");
      const workspaceId = workspaceIdFromResult(result.result);
      if (workspaceId !== null) {
        // Select it — useWorkspaceHashRoute repairs against the next snapshot.
        setHashRoute({ workspaceId, paneId: null, params: {} });
      } else {
        // Result shape unrecognized — the SSE snapshot.updated refetch picks
        // it up; just reselect whatever is first.
        useWorkspacesStore.getState().refresh();
      }
      onClose();
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="tools-modal-backdrop" onClick={onClose}>
      <form
        className="tools-modal create-ws-modal"
        role="dialog"
        aria-label="new workspace"
        onClick={(event) => event.stopPropagation()}
        onSubmit={submit}
      >
        <div className="tools-modal-header">
          <span className="tools-modal-title">new workspace</span>
          <button type="button" className="diff-sheet-done" onClick={onClose}>
            Done
          </button>
        </div>
        <div className="create-ws-body">
          <label className="create-ws-field">
            <span className="create-ws-field-label">Name</span>
            <input
              className="create-ws-input"
              type="text"
              value={name}
              placeholder="Name"
              aria-label="Name"
              autoFocus
              autoComplete="off"
              onChange={(event) => setName(event.target.value)}
            />
          </label>
          <label className="create-ws-field">
            <span className="create-ws-field-label">Folder path</span>
            <input
              className="create-ws-input"
              type="text"
              value={folder}
              placeholder="/path/to/folder"
              aria-label="Folder path"
              autoCapitalize="off"
              spellCheck={false}
              onChange={(event) => setFolder(event.target.value)}
            />
          </label>
          <p className="create-ws-info">
            Herdr opens one shell pane in this folder. Split panes or start an agent after it
            appears.
          </p>
          {error !== null ? <p className="create-ws-error">{error}</p> : null}
          <div className="create-ws-actions">
            <button type="button" className="hz-popover-button" onClick={onClose}>
              Cancel
            </button>
            <button
              type="submit"
              className="hz-popover-button hz-popover-button-primary"
              disabled={submitting || !name.trim()}
            >
              Create
            </button>
          </div>
        </div>
      </form>
    </div>
  );
}
