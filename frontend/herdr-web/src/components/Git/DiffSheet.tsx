import { useMemo } from "react";
import { FileDiff } from "lucide-react";
import {
  EMPTY_GIT_ENTRY,
  useGitStore,
  type DiffSheetState,
} from "../../store/gitStore";
import {
  lineCode,
  lineMarker,
  parseUnifiedDiffLines,
  type ParsedDiffLine,
} from "../../lib/unifiedDiff";
import "./git.css";

/**
 * The persistent diff half of the Git workbench.
 *
 * Diff state keeps its original `diffSheet` name in the store because that is
 * an internal loading model used by the API and store tests. It is no longer
 * presented as a sheet: the inspector stays beside the repository navigator.
 */
export function DiffInspector({ paneId }: { paneId: string }) {
  const sheet = useGitStore((state) =>
    state.diffSheet?.paneId === paneId ? state.diffSheet : null,
  );
  const entry = useGitStore((state) => state.byPane[paneId] ?? EMPTY_GIT_ENTRY);
  const lines = useMemo(() => parseUnifiedDiffLines(sheet?.diff ?? ""), [sheet?.diff]);

  if (sheet === null) {
    return (
      <section className="hz-diff-inspector hz-diff-inspector-empty" aria-label="Code changes">
        <FileDiff size={22} aria-hidden />
        <span className="hz-git-state-title">Select a changed file</span>
        <span className="hz-git-state-sub">Its diff will stay open here while you browse the repository.</span>
      </section>
    );
  }

  const revisionLabel =
    sheet.section === "commit" && sheet.commitHash !== null
      ? `commit ${sheet.commitHash.slice(0, 8)}`
      : sheet.section;

  return (
    <section className="hz-diff-inspector" aria-label={`Diff for ${sheet.file}`}>
      <header className="hz-diff-header">
        <div className="hz-diff-heading">
          <span className="hz-diff-eyebrow">{revisionLabel}</span>
          <span className="hz-diff-title mono" title={sheet.file}>
            {sheet.file}
          </span>
        </div>
        {entry.loading ? <span className="hz-diff-refreshing">Refreshing repository…</span> : null}
      </header>
      <div className="hz-diff-body">
        {sheet.isLoading ? (
          <p className="hz-diff-state" role="status">Loading diff…</p>
        ) : sheet.error !== null ? (
          <div className="hz-diff-state hz-diff-error">
            <span>Diff unavailable</span>
            <small>{sheet.error}</small>
            <button type="button" onClick={() => retryDiff(sheet)}>Try again</button>
          </div>
        ) : sheet.diff === "" ? (
          <p className="hz-diff-state hz-diff-empty">(empty diff)</p>
        ) : (
          lines.map((line) => <DiffLineRow key={line.id} line={line} />)
        )}
      </div>
    </section>
  );
}

function retryDiff(sheet: DiffSheetState) {
  if (sheet.section === "commit" && sheet.commitHash !== null) {
    useGitStore.getState().commitDiff(sheet.paneId, sheet.commitHash, sheet.file);
  } else if (sheet.section !== "commit") {
    useGitStore.getState().diff(sheet.paneId, sheet.file, sheet.section);
  }
}

function DiffLineRow({ line }: { line: ParsedDiffLine }) {
  return (
    <div className={`hz-diff-row hz-diff-row-${line.kind}`}>
      <span className="hz-diff-gutter">{line.oldLineNumber ?? ""}</span>
      <span className="hz-diff-gutter">{line.newLineNumber ?? ""}</span>
      <span className="hz-diff-marker">{lineMarker(line)}</span>
      <span className="hz-diff-text">{lineCode(line)}</span>
    </div>
  );
}
