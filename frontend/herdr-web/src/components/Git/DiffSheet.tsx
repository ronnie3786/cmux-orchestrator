import { useEffect, useMemo, useState } from "react";
import { registerCustomCSSVariableTheme } from "@pierre/diffs";
import { FileDiff as PierreFileDiff } from "@pierre/diffs/react";
import { Columns2, FileCode2, Rows3, TriangleAlert, WrapText } from "lucide-react";
import {
  EMPTY_GIT_ENTRY,
  useGitStore,
  type DiffSheetState,
} from "../../store/gitStore";
import { parseDiffPresentation } from "./diffPresentation";
import "./git.css";

type DiffStyle = "unified" | "split";
type DiffOverflow = "scroll" | "wrap";

const DIFF_STYLE_KEY = "herdr.git.diff-style";
const DIFF_OVERFLOW_KEY = "herdr.git.diff-overflow";
const HERDR_DIFF_THEME = "herdr-dark";

registerCustomCSSVariableTheme(HERDR_DIFF_THEME, {
  foreground: "#e8eaed",
  background: "#0b0e13",
  "token-comment": "#7d8590",
  "token-string": "#a5d6ff",
  "token-constant": "#79c0ff",
  "token-keyword": "#ff7b72",
  "token-parameter": "#e8eaed",
  "token-function": "#d2a8ff",
  "token-string-expression": "#7ee787",
  "token-punctuation": "#8b949e",
  "token-link": "#58a6ff",
  "ansi-black": "#484f58",
  "ansi-red": "#ff7b72",
  "ansi-green": "#7ee787",
  "ansi-yellow": "#e3b341",
  "ansi-blue": "#79c0ff",
  "ansi-magenta": "#d2a8ff",
  "ansi-cyan": "#56d4dd",
  "ansi-white": "#e8eaed",
});

const PIERRE_THEME_OVERRIDES = `
  :host {
    --diffs-font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    --diffs-header-font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    --diffs-font-size: 11.5px;
    --diffs-line-height: 1.55;
    --diffs-bg: #0b0e13;
    --diffs-bg-context: #0b0e13;
    --diffs-bg-context-gutter: #0d1117;
    --diffs-bg-separator: #11161e;
    --diffs-bg-addition-override: rgba(48, 209, 88, 0.11);
    --diffs-bg-addition-number-override: rgba(48, 209, 88, 0.16);
    --diffs-bg-deletion-override: rgba(255, 69, 58, 0.11);
    --diffs-bg-deletion-number-override: rgba(255, 69, 58, 0.16);
    --diffs-bg-hover-override: rgba(47, 129, 247, 0.09);
    --diffs-bg-selection-override: rgba(47, 129, 247, 0.18);
    --diffs-bg-selection-number-override: rgba(47, 129, 247, 0.28);
  }
`;

/**
 * The persistent diff half of the Git workbench.
 *
 * Diff state keeps its original `diffSheet` name in the store because that is
 * an internal loading model used by the API and store tests. It is no longer
 * presented as a sheet: the inspector stays beside the repository navigator.
 */
export function DiffInspector({ paneId }: { paneId: string }) {
  const [diffStyle, setDiffStyle] = useState<DiffStyle>(() =>
    storedPreference(DIFF_STYLE_KEY, "unified", ["unified", "split"]),
  );
  const [diffOverflow, setDiffOverflow] = useState<DiffOverflow>(() =>
    storedPreference(DIFF_OVERFLOW_KEY, "scroll", ["scroll", "wrap"]),
  );
  const sheet = useGitStore((state) =>
    state.diffSheet?.paneId === paneId ? state.diffSheet : null,
  );
  const entry = useGitStore((state) => state.byPane[paneId] ?? EMPTY_GIT_ENTRY);
  const parsed = useMemo(
    () => parseDiffPresentation(sheet?.file ?? "", sheet?.diff ?? ""),
    [sheet?.diff, sheet?.file],
  );

  useEffect(() => persistPreference(DIFF_STYLE_KEY, diffStyle), [diffStyle]);
  useEffect(() => persistPreference(DIFF_OVERFLOW_KEY, diffOverflow), [diffOverflow]);

  if (sheet === null) {
    return (
      <section className="hz-diff-inspector hz-diff-inspector-empty" aria-label="Code changes">
        <FileCode2 size={22} aria-hidden />
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
        <div className="hz-diff-controls" aria-label="Diff display options">
          <div className="hz-diff-segment" role="group" aria-label="Diff layout">
            <button
              type="button"
              className={diffStyle === "unified" ? "hz-diff-control-active" : ""}
              onClick={() => setDiffStyle("unified")}
              aria-pressed={diffStyle === "unified"}
              title="Unified diff"
            >
              <Rows3 size={13} aria-hidden />
              <span>Unified</span>
            </button>
            <button
              type="button"
              className={diffStyle === "split" ? "hz-diff-control-active" : ""}
              onClick={() => setDiffStyle("split")}
              aria-pressed={diffStyle === "split"}
              title="Split diff"
            >
              <Columns2 size={13} aria-hidden />
              <span>Split</span>
            </button>
          </div>
          <button
            type="button"
            className={`hz-diff-wrap${diffOverflow === "wrap" ? " hz-diff-control-active" : ""}`}
            onClick={() => setDiffOverflow((current) => (current === "wrap" ? "scroll" : "wrap"))}
            aria-pressed={diffOverflow === "wrap"}
            title={diffOverflow === "wrap" ? "Disable line wrapping" : "Wrap long lines"}
          >
            <WrapText size={13} aria-hidden />
            <span>Wrap</span>
          </button>
        </div>
        {entry.loading ? <span className="hz-diff-refreshing">Refreshing repository…</span> : null}
      </header>
      {sheet.truncated ? (
        <div className="hz-diff-truncated-warning" role="alert" aria-atomic="true">
          <TriangleAlert size={16} aria-hidden />
          <div>
            <strong>Diff truncated</strong>
            <span>The server returned only part of this patch. This review may be incomplete.</span>
          </div>
        </div>
      ) : null}
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
        ) : parsed.fileDiff !== null ? (
          <PierreFileDiff
            key={parsed.fileDiff.cacheKey}
            fileDiff={parsed.fileDiff}
            options={{
              themeType: "dark",
              theme: { dark: HERDR_DIFF_THEME, light: HERDR_DIFF_THEME },
              unsafeCSS: PIERRE_THEME_OVERRIDES,
              disableFileHeader: true,
              diffStyle,
              overflow: diffOverflow,
              diffIndicators: "bars",
              lineDiffType: "word-alt",
              hunkSeparators: "line-info",
              lineHoverHighlight: "both",
            }}
          />
        ) : (
          <div className="hz-diff-plain-fallback">
            <span>
              {parsed.fallbackReason === "metadata-only"
                ? "This change contains Git metadata rather than line-by-line text. Showing the raw patch."
                : "Syntax rendering was unavailable for this patch. Showing the raw diff."}
            </span>
            <pre>{sheet.diff}</pre>
          </div>
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

function storedPreference<T extends string>(key: string, fallback: T, allowed: readonly T[]): T {
  if (typeof window === "undefined") return fallback;
  try {
    const value = window.localStorage.getItem(key);
    return value !== null && allowed.includes(value as T) ? (value as T) : fallback;
  } catch {
    return fallback;
  }
}

function persistPreference(key: string, value: string) {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(key, value);
  } catch {
    // Display preferences are optional when storage is unavailable.
  }
}
