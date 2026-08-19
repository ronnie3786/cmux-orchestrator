import { useCallback, useEffect, useRef, useState } from "react";
import { AlertTriangle, AtSign, FileSearch, FileText } from "lucide-react";
import { workspaceFiles, type WorkspaceFileMatch } from "../../api/tools";
import { useEscapeLayer, useScrollLock } from "../../hooks/useOverlay";

interface FileSearchModalProps {
  workspaceId: string;
  /** Called with the workspace-relative file path on row tap. */
  onPick: (path: string) => void;
  onClose: () => void;
}

/**
 * Command Lens "@ file" sheet (P9-run-B) — port of the Phase-1 FileSearchModal
 * re-pointed at GET /api/v1/workspaces/{id}/files?q&limit=80 (doc 02 §2).
 *
 * - ≥3 trimmed chars before querying; per-keystroke re-issue with
 *   cancellation (only the latest query's results render).
 * - Strings byte-exact per doc 01 §6: "WORKSPACE FILES", "MATCHES",
 *   "Done", "Retry" (Phase-1 strings where §6 is silent: "Search Files",
 *   "No Matches", the search placeholder).
 */
export function FileSearchModal({ workspaceId, onPick, onClose }: FileSearchModalProps) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<WorkspaceFileMatch[]>([]);
  const [searching, setSearching] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const inputRef = useRef<HTMLInputElement>(null);
  const abortRef = useRef<AbortController | null>(null);
  /** The trimmed query the pending/last-applied results belong to. */
  const latestQueryRef = useRef<string>("");

  const trimmed = query.trim();

  const runSearch = useCallback(
    (value: string) => {
      abortRef.current?.abort();
      setError(null);
      const q = value.trim();
      if (q.length < 3) {
        latestQueryRef.current = "";
        setResults([]);
        setSearching(false);
        return;
      }
      latestQueryRef.current = q;
      setSearching(true);
      const controller = new AbortController();
      abortRef.current = controller;
      workspaceFiles(workspaceId, q, controller.signal)
        .then((response) => {
          if (latestQueryRef.current !== q) return;
          setSearching(false);
          setError(null);
          setResults(response.files ?? []);
        })
        .catch((err) => {
          if (latestQueryRef.current !== q) return;
          setSearching(false);
          if (err instanceof Error && err.message === "Request cancelled") return;
          setError(err instanceof Error ? err.message : "File search failed");
        });
    },
    [workspaceId],
  );

  // Autofocus on open; cancel the in-flight request on close.
  useEffect(() => {
    inputRef.current?.focus();
    return () => abortRef.current?.abort();
  }, []);

  useEscapeLayer(onClose);
  useScrollLock(true);

  const spinner = (
    <div className="tools-modal-spinner-wrap">
      <div className="spinner" aria-label="Searching" />
    </div>
  );

  return (
    <div className="tools-modal-backdrop" onClick={onClose}>
      <div
        className="tools-modal file-search-modal"
        role="dialog"
        aria-label="File search"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="tools-modal-header">
          <span className="tools-modal-title">WORKSPACE FILES</span>
          <button type="button" className="diff-sheet-done" onClick={onClose}>
            Done
          </button>
        </div>
        <div className="tools-modal-search">
          <input
            ref={inputRef}
            className="tools-modal-search-input"
            type="text"
            value={query}
            placeholder="Search project files"
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            aria-label="Search project files"
            onChange={(event) => {
              setQuery(event.target.value);
              runSearch(event.target.value);
            }}
          />
        </div>
        <div className="tools-modal-body">
          {trimmed.length < 3 ? (
            <div className="tools-modal-empty">
              <AtSign size={20} aria-hidden />
              <span>Search Files</span>
            </div>
          ) : searching && results.length === 0 ? (
            spinner
          ) : error !== null ? (
            <div className="git-error">
              <span className="git-error-text">
                <AlertTriangle size={13} aria-hidden /> {error}
              </span>
              <button type="button" className="git-error-retry" onClick={() => runSearch(query)}>
                Retry
              </button>
            </div>
          ) : results.length === 0 ? (
            <div className="tools-modal-empty">
              <FileSearch size={20} aria-hidden />
              <span>No Matches</span>
            </div>
          ) : (
            <>
              <div className="jira-section-header">MATCHES</div>
              <div className="file-search-results">
                {results.map((file) => (
                  <button
                    key={file.path}
                    type="button"
                    className="file-search-row"
                    onClick={() => onPick(file.path)}
                  >
                    <FileText size={15} className="file-search-row-icon" aria-hidden />
                    <span className="file-search-row-path" title={file.path}>
                      {file.path}
                    </span>
                  </button>
                ))}
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
