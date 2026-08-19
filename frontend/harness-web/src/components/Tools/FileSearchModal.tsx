import { useCallback, useEffect, useRef, useState } from "react";
import { AlertTriangle, AtSign, FileSearch, FileText } from "lucide-react";
import { fileSearch } from "../../api/endpoints";
import type { ProjectFileMatch } from "../../api/types";
import { useDraftStore } from "../../store/draftStore";
import { useEscapeLayer, useScrollLock } from "../../hooks/useOverlay";

interface FileSearchModalProps {
  /** cmux index of the selected session. */
  index: number;
  /** Switch the detail view to the Terminal tab (iOS `detailTab = .terminal`). */
  onJumpToTerminal: () => void;
  onClose: () => void;
}

/**
 * iOS `FileSearchView` + `HarnessFeatureToolsReducer` file-search state parity.
 *
 * - ≥3 trimmed chars before querying (iOS `trimmedQuery.count >= 3`).
 * - Per-keystroke re-issue with cancellation: each change aborts the previous
 *   request (iOS `fileSearchCancelID` / `cancelInFlight: true`), and only the
 *   latest query's results render (iOS `fileSearchSucceeded` guard compares
 *   the stored query against the current one).
 * - Row tap: append `` `path` `` to the draft (iOS `appendPromptToken` —
 *   backticked, space-separated, exact), jump to the Terminal tab, focus the
 *   input row, and close the modal (iOS `.appendFilePath`).
 * - Display state order mirrors the view: <3 chars → "Search Files" hint;
 *   searching with no results → spinner; error → banner + retry (re-issues
 *   the current query, iOS `fileSearchQueryChanged(current)`); no results →
 *   "No Matches"; else rows. Stale results stay visible while a new search is
 *   in flight (iOS keeps `fileSearchResults` until the response lands).
 */
export function FileSearchModal({ index, onJumpToTerminal, onClose }: FileSearchModalProps) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<ProjectFileMatch[]>([]);
  const [searching, setSearching] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const inputRef = useRef<HTMLInputElement>(null);
  /** AbortController of the in-flight request (iOS fileSearchCancelID). */
  const abortRef = useRef<AbortController | null>(null);
  /** The trimmed query the pending/last-applied results belong to. */
  const latestQueryRef = useRef<string>("");

  const trimmed = query.trim();

  // iOS `.fileSearchQueryChanged`: re-issue per keystroke, cancel in flight.
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
      fileSearch(index, q, controller.signal)
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
    [index],
  );

  // Autofocus on open (iOS `.onAppear { isSearchFocused = true }`); cancel the
  // in-flight request on close (iOS `.dismissFileSearch` cancels the task).
  useEffect(() => {
    inputRef.current?.focus();
    return () => abortRef.current?.abort();
  }, []);

  // Close on Escape (web idiom; iOS uses the Done button) — top-most layer only.
  useEscapeLayer(onClose);
  useScrollLock(true);

  // iOS `.appendFilePath`: backticked path token + terminal + focus + close.
  const insertPath = (path: string) => {
    useDraftStore.getState().appendToken(`\`${path}\``);
    useDraftStore.getState().requestFocus();
    onJumpToTerminal();
    onClose();
  };

  const spinner = <div className="tools-modal-spinner-wrap"><div className="spinner" aria-label="Searching" /></div>;

  return (
    <div className="tools-modal-backdrop" onClick={onClose}>
      <div
        className="tools-modal file-search-modal"
        role="dialog"
        aria-label="File search"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="tools-modal-header">
          <span className="tools-modal-title">Files</span>
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
            <div className="file-search-results">
              {results.map((file) => (
                <button
                  key={file.path}
                  type="button"
                  className="file-search-row"
                  onClick={() => insertPath(file.path)}
                >
                  <FileText size={15} className="file-search-row-icon" aria-hidden />
                  <span className="file-search-row-path" title={file.path}>
                    {file.path}
                  </span>
                </button>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
