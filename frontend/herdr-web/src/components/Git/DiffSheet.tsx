/**
 * Diff sheet (P11-run-A) — line-colored unified diff overlay for one
 * file/section (doc 01 §4: "diff sheet with line-colored unified diff").
 * States byte-exact per doc 01 §6: `Loading diff…`, `Diff unavailable` (+
 * retry), `(empty diff)`, `Done`.
 */

import { useEscapeLayer, useScrollLock } from "../../hooks/useOverlay";
import { useGitStore } from "../../store/gitStore";
import {
  lineCode,
  lineMarker,
  parseUnifiedDiffLines,
  type ParsedDiffLine,
} from "../../lib/unifiedDiff";
import "./git.css";

export function DiffSheet() {
  const sheet = useGitStore((state) => state.diffSheet);
  const closeDiff = useGitStore((state) => state.closeDiff);

  useEscapeLayer(closeDiff, sheet !== null);
  useScrollLock(sheet !== null);

  if (sheet === null) return null;

  const lines = parseUnifiedDiffLines(sheet.diff);
  const retry = () => useGitStore.getState().diff(sheet.file, sheet.section);

  return (
    <div className="hz-diff-backdrop">
      <div className="hz-diff-sheet" role="dialog" aria-label={`Diff for ${sheet.file}`}>
        <div className="hz-diff-header">
          <span className="hz-diff-title mono" title={sheet.file}>
            {sheet.file}
          </span>
          <span className="hz-diff-section">{sheet.section}</span>
          <button type="button" className="hz-diff-done" onClick={closeDiff}>
            Done
          </button>
        </div>
        <div className="hz-diff-body">
          {sheet.isLoading ? (
            <p className="hz-diff-state">Loading diff…</p>
          ) : sheet.error !== null ? (
            <div className="hz-diff-state hz-diff-error">
              <span>Diff unavailable</span>
              <button type="button" onClick={retry}>
                Try again
              </button>
            </div>
          ) : sheet.diff === "" ? (
            <p className="hz-diff-state hz-diff-empty">(empty diff)</p>
          ) : (
            lines.map((line) => <DiffLineRow key={line.id} line={line} />)
          )}
        </div>
      </div>
    </div>
  );
}

function DiffLineRow({ line }: { line: ParsedDiffLine }) {
  const className = `hz-diff-row hz-diff-row-${line.kind}`;
  return (
    <div className={className}>
      <span className="hz-diff-gutter">{line.oldLineNumber ?? ""}</span>
      <span className="hz-diff-gutter">{line.newLineNumber ?? ""}</span>
      <span className="hz-diff-marker">{lineMarker(line)}</span>
      <span className="hz-diff-text">{lineCode(line)}</span>
    </div>
  );
}
