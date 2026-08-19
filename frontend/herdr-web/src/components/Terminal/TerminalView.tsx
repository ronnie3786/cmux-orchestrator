import { useEffect, type ReactNode } from "react";
import { getToken } from "../../api/client";
import { useTerminalStore } from "../../store/terminalStore";
import { useWorkspacesStore } from "../../store/workspacesStore";
import "./terminal.css";

/**
 * Terminal detail region (P5). Watches the hash-route-selected pane:
 * pane change → openPane(newId) (which closes the previous pane);
 * unmount → closePane().
 *
 * Toolbar: source dot + lowercase source label (byte-exact, doc 01 §6) and
 * the `W×H · fN` metadata (`rN` snapshot revision while watching). Body:
 * the grid's styled runs (renderSource "stream") or the plain snapshot
 * lines (renderSource "snapshot"), both selectable monospace.
 */
export function TerminalView() {
  const paneId = useWorkspacesStore((state) => state.selectedPaneId);
  const source = useTerminalStore((state) => state.source);
  const frameSequence = useTerminalStore((state) => state.frameSequence);
  const cols = useTerminalStore((state) => state.cols);
  const rows = useTerminalStore((state) => state.rows);
  const snapshotRevision = useTerminalStore((state) => state.snapshotRevision);
  const snapshotText = useTerminalStore((state) => state.snapshotText);
  const renderSource = useTerminalStore((state) => state.renderSource);
  const lastError = useTerminalStore((state) => state.lastError);
  const grid = useTerminalStore((state) => state.grid);

  useEffect(() => {
    if (paneId === null) {
      useTerminalStore.getState().closePane();
      return;
    }
    // openPane() closes any previously open pane first.
    useTerminalStore.getState().openPane(paneId, getToken());
    return () => {
      useTerminalStore.getState().closePane();
    };
  }, [paneId]);

  const streamRows = grid !== null ? grid.visibleRows(true) : [];
  const hasData =
    renderSource === "snapshot"
      ? (snapshotText ?? "").length > 0
      : streamRows.some((row) => row.some((run) => run.text.replace(/\s/g, "") !== ""));

  let body: ReactNode;
  if (source === "offline") {
    body = <p className="hz-terminal-message">{lastError ?? "Terminal offline."}</p>;
  } else if (source === "connecting" && !hasData) {
    body = <p className="hz-terminal-message">Connecting to terminal…</p>;
  } else if (renderSource === "snapshot") {
    body = (
      <div className="hz-terminal-viewport">
        {(snapshotText ?? "").split("\n").map((line, index) => (
          <div className="hz-terminal-line" key={index}>
            {line === "" ? "\u00A0" : line}
          </div>
        ))}
      </div>
    );
  } else {
    body =
      streamRows.length === 0 ? (
        <p className="hz-terminal-message">No terminal output yet.</p>
      ) : (
        <div className="hz-terminal-viewport">
          {streamRows.map((row, rowIndex) => (
            <div className="hz-terminal-line" key={rowIndex}>
              {row.length === 0
                ? "\u00A0"
                : row.map((run, runIndex) => (
                    <span
                      key={runIndex}
                      className={run.cursor ? "hz-terminal-cursor" : undefined}
                      style={{
                        color: run.foreground,
                        backgroundColor: run.background ?? undefined,
                        fontWeight: run.bold ? 700 : 400,
                        fontStyle: run.italic ? "italic" : "normal",
                        textDecoration: run.underline ? "underline" : "none",
                      }}
                    >
                      {run.text}
                    </span>
                  ))}
            </div>
          ))}
        </div>
      );
  }

  return (
    <main className="hz-detail-col hz-terminal-col">
      <div className="hz-terminal-toolbar">
        <span className="hz-terminal-source">
          <span className={`hz-terminal-dot hz-terminal-dot-${source}`} aria-hidden />
          {source}
        </span>
        <span className="hz-terminal-meta">
          {cols}×{rows} · {source === "watching" ? `r${snapshotRevision ?? 0}` : `f${frameSequence}`}
        </span>
        <button
          type="button"
          className="hz-terminal-refresh"
          onClick={() => useTerminalStore.getState().refreshNow()}
        >
          refresh
        </button>
      </div>
      {body}
    </main>
  );
}
