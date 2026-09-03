import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import { Loader2, SendHorizontal, Sparkles, Square, X } from "lucide-react";
import {
  cancelAgentRun,
  getAgentRun,
  isTerminalRunStatus,
  startAgentRun,
  type AgentRun,
} from "../../api/agentRuns";
import { MarkdownText } from "../Pi/MarkdownBlocks";
import "../Pi/pi.css";
import { formatLineRange, summarizeCode, type SelectionAskContext } from "./selectionAsk";

const POLL_INTERVAL_MS = 900;
const MAX_VISIBLE_STEPS = 24;

export interface InlineAskAnchor {
  left: number;
  top: number;
}

interface InlineAskTurn {
  question: string;
  runId: string | null;
  response: string | null;
  error: string | null;
  running: boolean;
  steps: string[];
}

interface InlineAskPanelProps {
  paneId: string;
  file: string;
  context: SelectionAskContext;
  anchor: InlineAskAnchor;
  onClose: () => void;
}

/**
 * Inline "ask about this code" chat. Each question starts a pane-scoped
 * headless agent run (the same engine as the HUD); follow-ups continue the
 * run thread so the agent keeps the conversation's context.
 */
export function InlineAskPanel({ paneId, file, context, anchor, onClose }: InlineAskPanelProps) {
  const [turns, setTurns] = useState<InlineAskTurn[]>([]);
  const [draft, setDraft] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);
  const latestRunRef = useRef<string | null>(null);
  const activeRunRef = useRef<string | null>(null);
  const closedRef = useRef(false);

  useEffect(() => {
    closedRef.current = false;
    return () => {
      closedRef.current = true;
      // Closing the panel stops a still-running ask; completed answers stay.
      const activeRun = activeRunRef.current;
      if (activeRun !== null) {
        void cancelAgentRun(activeRun).catch(() => undefined);
      }
    };
  }, []);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight });
  }, [turns]);

  useEffect(() => {
    const onKey = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const rangeLabel = formatLineRange(context.startLine, context.endLine);

  const submit = async () => {
    const question = draft.trim();
    if (question === "" || submitting) return;
    setDraft("");
    setSubmitting(true);
    const turn: InlineAskTurn = {
      question,
      runId: null,
      response: null,
      error: null,
      running: true,
      steps: [],
    };
    const turnIndex = turns.length;
    setTurns((current) => [...current, turn]);
    try {
      const started = await startAgentRun({
        prompt: question,
        mode: "ask",
        label: `Ask about ${file}`.slice(0, 120),
        paneId,
        continueFromRunId: latestRunRef.current ?? undefined,
      });
      if (closedRef.current) {
        void cancelAgentRun(started.run.id).catch(() => undefined);
        return;
      }
      latestRunRef.current = started.run.id;
      activeRunRef.current = started.run.id;
      setTurns((current) =>
        current.map((item, index) => (index === turnIndex ? { ...item, runId: started.run.id } : item)),
      );
      await pollRun(started.run.id, turnIndex);
    } catch (error) {
      if (closedRef.current) return;
      setTurns((current) =>
        current.map((item, index) =>
          index === turnIndex
            ? { ...item, running: false, error: errorMessage(error) }
            : item,
        ),
      );
    } finally {
      setSubmitting(false);
    }
  };

  const pollRun = async (runId: string, turnIndex: number) => {
    for (;;) {
      await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
      if (closedRef.current) return;
      let run: AgentRun;
      try {
        run = (await getAgentRun(runId)).run;
      } catch (error) {
        setTurns((current) =>
          current.map((item, index) =>
            index === turnIndex ? { ...item, running: false, error: errorMessage(error) } : item,
          ),
        );
        return;
      }
      const steps = stepSummaries(run);
      setTurns((current) =>
        current.map((item, index) =>
          index === turnIndex
            ? {
                ...item,
                steps,
                running: !isTerminalRunStatus(run.status),
                response: run.response,
                error: run.error,
              }
            : item,
        ),
      );
      if (isTerminalRunStatus(run.status)) {
        if (activeRunRef.current === runId) {
          activeRunRef.current = null;
        }
        return;
      }
    }
  };

  const cancelRunning = async () => {
    const runId = latestRunRef.current;
    if (runId === null) return;
    try {
      await cancelAgentRun(runId);
    } catch {
      // The run may have finished between render and cancel; polling will settle.
    }
  };

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      void submit();
    }
  };

  const anyRunning = submitting || turns.some((turn) => turn.running);

  return (
    <section
      className="hz-inline-ask"
      style={{ left: anchor.left, top: anchor.top }}
      role="dialog"
      aria-label="Ask the agent about the selected code"
    >
      <header className="hz-inline-ask-header">
        <Sparkles size={14} className="hz-inline-ask-sparkle" aria-hidden />
        <div className="hz-inline-ask-heading">
          <span className="hz-inline-ask-title">Ask about this code</span>
          <span className="hz-inline-ask-context mono" title={file}>
            {file}
            {rangeLabel !== null ? ` · ${rangeLabel}` : ""}
          </span>
        </div>
        <button
          type="button"
          className="hz-inline-ask-close"
          aria-label="Close inline chat"
          onClick={onClose}
        >
          <X size={14} aria-hidden />
        </button>
      </header>

      <div className="hz-inline-ask-selection" title={context.code}>
        <span className="mono">{summarizeCode(context.code) || "(no text selected)"}</span>
      </div>

      <div className="hz-inline-ask-scroll" ref={scrollRef}>
        {turns.length === 0 ? (
          <p className="hz-inline-ask-hint">
            Ask anything about the highlighted code — the agent runs in this repository and can
            read the surrounding files.
          </p>
        ) : (
          turns.map((turn, index) => (
            <div className="hz-inline-ask-turn" key={index}>
              <div className="hz-inline-ask-question">{turn.question}</div>
              {turn.response !== null && turn.response !== "" ? (
                <div className="hz-inline-ask-answer hz-md">
                  <MarkdownText text={turn.response} />
                </div>
              ) : null}
              {turn.steps.length > 0 && turn.running ? (
                <div className="hz-inline-ask-steps mono" aria-live="polite">
                  <Loader2 size={11} className="hz-git-state-spinner" aria-hidden />
                  <span>{turn.steps[turn.steps.length - 1]}</span>
                </div>
              ) : null}
              {turn.error !== null ? (
                <div className="hz-inline-ask-error" role="alert">
                  {turn.error}
                </div>
              ) : null}
            </div>
          ))
        )}
      </div>

      <footer className="hz-inline-ask-composer">
        <textarea
          rows={2}
          value={draft}
          placeholder={anyRunning ? "Waiting for the agent…" : "Why is this here?"}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={onKeyDown}
          disabled={anyRunning}
          aria-label="Question about the selected code"
        />
        <div className="hz-inline-ask-actions">
          {anyRunning ? (
            <button type="button" className="hz-inline-ask-send" onClick={() => void cancelRunning()}>
              <Square size={12} aria-hidden />
              <span>Stop</span>
            </button>
          ) : (
            <button
              type="button"
              className="hz-inline-ask-send"
              onClick={() => void submit()}
              disabled={draft.trim() === ""}
            >
              <SendHorizontal size={12} aria-hidden />
              <span>Ask</span>
            </button>
          )}
        </div>
      </footer>
    </section>
  );
}

function stepSummaries(run: AgentRun): string[] {
  const steps = run.steps ?? [];
  return steps.slice(-MAX_VISIBLE_STEPS).map((step) => {
    const suffix = step.isError ? " (failed)" : "";
    return `${step.toolName}${suffix}`;
  });
}

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message !== "") return error.message;
  return "The agent request failed.";
}