import { memo, useEffect, useRef } from "react";
import type { CSSProperties } from "react";
import { renderANSIBlock, type Run } from "../../terminal/ansi";

interface TerminalViewProps {
  /** Full screen text (ANSI escapes included). Byte-identical text skips re-render. */
  text: string;
  /** Selection identity — resets scroll position when it changes. */
  sessionID: string;
}

/** Distance from the bottom (px) within which auto-scroll stays "stuck". */
const STICK_TO_BOTTOM_PX = 80;

function runStyle(run: Run): CSSProperties | undefined {
  if (run.fg === undefined && run.bg === undefined && !run.bold && !run.italic && !run.underline) {
    return undefined;
  }
  const style: CSSProperties = {};
  if (run.fg !== undefined) style.color = run.fg;
  if (run.bg !== undefined) style.backgroundColor = run.bg;
  if (run.bold) style.fontWeight = 600; // iOS renders bold as .semibold
  if (run.italic) style.fontStyle = "italic";
  if (run.underline) style.textDecoration = "underline";
  return style;
}

function TerminalViewInner({ text, sessionID }: TerminalViewProps) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const stickToBottomRef = useRef(true);

  // New session: jump to the bottom (iOS defaultScrollAnchor(.bottom)).
  useEffect(() => {
    stickToBottomRef.current = true;
    const el = scrollRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [sessionID]);

  // New content: follow the bottom only when the user is already near it —
  // never yank the view down if they scrolled up to read.
  useEffect(() => {
    const el = scrollRef.current;
    if (el && stickToBottomRef.current) el.scrollTop = el.scrollHeight;
  }, [text]);

  if (!text) {
    return <div className="term term-empty">(no terminal data yet)</div>;
  }

  const lines = renderANSIBlock(text);

  return (
    <div
      className="term"
      ref={scrollRef}
      onScroll={() => {
        const el = scrollRef.current;
        if (!el) return;
        stickToBottomRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < STICK_TO_BOTTOM_PX;
      }}
    >
      {lines.map((runs, i) => (
        <div className="term-line" key={i}>
          {runs.map((run, j) => (
            <span key={j} style={runStyle(run)}>
              {run.text}
            </span>
          ))}
        </div>
      ))}
    </div>
  );
}

export const TerminalView = memo(TerminalViewInner);
