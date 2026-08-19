/**
 * Pi chat detail region (P8-run-A). Two parts:
 *
 *  - `PiChatView` — presentational timeline over the reducer's published
 *    state (banner, context meter, truncation header, turns, empty state,
 *    composer mount point for run-B).
 *  - `PiChatPane` — wiring: follows the selected pane's Pi semantic
 *    capability in piStore (follow on select, stop on deselect/unmount)
 *    and pipes the store's state into `PiChatView`.
 *
 * Connection banners use the store's state machine (P7) rendered with the
 * byte-exact view strings (doc 01 §4.4/§6); the store's `lastError` detail
 * is shown under the banner when present (the generic offline detail is
 * suppressed — the banner already says it).
 */
import { useEffect, useRef, useState } from "react";
import { getToken } from "../../api/client";
import { parsePiMarkdown } from "../../pi/markdown";
import { usePiStore } from "../../store/piStore";
import { useWorkspacesStore } from "../../store/workspacesStore";
import {
  decodePiSemanticCapability,
  piContextUsageFraction,
  piContextUsagePercentText,
  piContextUsageSummary,
  piTurnHasVisibleContent,
} from "../../pi/types";
import type {
  PiAssistantStatus,
  PiContextUsage,
  PiConversationConnection,
  PiConversationPhase,
  PiConversationTurn,
  PiJSONValue,
  PiPendingInteraction,
  PiSemanticCapability,
  PiThinkingBlock,
  PiToolInvocation,
} from "../../pi/types";
import { MarkdownBlocks, MarkdownText } from "./MarkdownBlocks";
import { ToolCard, formatElapsed } from "./ToolCard";
import "./pi.css";

/** The store's generic bridge-offline detail (piStore) — redundant with the banner. */
const BRIDGE_OFFLINE_DETAIL = "Pi is offline. The saved transcript is still available.";

export interface PiChatViewProps {
  connection: PiConversationConnection;
  lastError: string | null;
  turns: PiConversationTurn[];
  phase: PiConversationPhase;
  isTruncated: boolean;
  contextUsage: PiContextUsage | null;
  pendingInteractions?: PiPendingInteraction[];
}

export function PiChatView({
  connection,
  lastError,
  turns,
  phase,
  isTruncated,
  contextUsage,
  pendingInteractions = [],
}: PiChatViewProps) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const atBottomRef = useRef(true);
  const [showJump, setShowJump] = useState(false);

  // 1 s tick only while something live is visible (streaming thinking, a
  // running tool's elapsed time).
  const live = turns.some((turn) =>
    turn.items.some(
      (item) =>
        (item.kind === "thinking" && item.value.isStreaming) ||
        (item.kind === "tool" && item.value.status === "running"),
    ),
  );
  const now = useTicker(live);

  const onScroll = () => {
    const el = scrollRef.current;
    if (el === null) return;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 48;
    atBottomRef.current = atBottom;
    setShowJump(!atBottom);
  };
  // Auto-stick: new content lands at the bottom while the reader is at the bottom.
  useEffect(() => {
    const el = scrollRef.current;
    if (el !== null && atBottomRef.current) {
      el.scrollTop = el.scrollHeight;
    }
  });

  const jumpToLatest = () => {
    const el = scrollRef.current;
    if (el === null) return;
    el.scrollTop = el.scrollHeight;
    atBottomRef.current = true;
    setShowJump(false);
  };

  const banner = bannerFor(connection);
  const detail =
    banner !== null && lastError !== null && lastError !== BRIDGE_OFFLINE_DETAIL
      ? lastError
      : null;
  const hasContent = turns.some(piTurnHasVisibleContent);
  const pendingCount = pendingInteractions.length;

  return (
    <main className="hz-detail-col hz-pi-col">
      {banner !== null && (
        <div className={`hz-pi-banner hz-pi-banner-${banner.tone}`} role="status">
          <span className="hz-pi-banner-text">{banner.text}</span>
          {detail !== null && <span className="hz-pi-banner-detail">{detail}</span>}
        </div>
      )}
      {contextUsage !== null && <ContextMeter usage={contextUsage} />}

      <div className="hz-pi-scroll" ref={scrollRef} onScroll={onScroll}>
        {hasContent ? (
          <div className="hz-pi-timeline">
            {isTruncated && (
              <p className="hz-pi-truncated">Older context was omitted by Pi</p>
            )}
            {turns.map((turn) => (
              <TurnView key={turn.id} turn={turn} now={now} />
            ))}
          </div>
        ) : (
          <div className="hz-pi-empty">
            <p className="hz-pi-empty-title">
              {phase === "working" ? "Pi is starting…" : "Start a conversation"}
            </p>
            <p className="hz-pi-empty-copy">
              Messages, thinking, and tool activity will appear here. The terminal remains
              available from the pane menu.
            </p>
          </div>
        )}
      </div>

      {showJump && (
        <button type="button" className="hz-pi-jump" onClick={jumpToLatest}>
          Jump to latest
        </button>
      )}
      {pendingCount > 0 && (
        <p className="hz-pi-interactions" aria-live="polite">
          Pi needs your input
        </p>
      )}
      {/* Composer mounts here in run-B. */}
      <div data-pi-composer-mount />
    </main>
  );
}

function useTicker(active: boolean): number {
  const [now, setNow] = useState<number>(() => Date.now());
  useEffect(() => {
    if (!active) return;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [active]);
  return now;
}

// ---------------------------------------------------------------------------
// Banner (store connection state → byte-exact view string)
// ---------------------------------------------------------------------------

function bannerFor(
  connection: PiConversationConnection,
): { text: string; tone: "neutral" | "warning" | "error" } | null {
  switch (connection.state) {
    case "loading":
      return { text: "Loading native transcript…", tone: "neutral" };
    case "bridgeOffline":
      return { text: "Pi is offline. Transcript preserved.", tone: "warning" };
    case "reconnecting":
      return { text: "Reconnecting to Pi…", tone: "warning" };
    case "unavailable":
      return { text: "Native transcript unavailable", tone: "error" };
    case "connected":
      return null;
  }
}

// ---------------------------------------------------------------------------
// Context meter
// ---------------------------------------------------------------------------

function ContextMeter({ usage }: { usage: PiContextUsage }) {
  const fraction = piContextUsageFraction(usage);
  if (fraction === null) return null;
  const summary = piContextUsageSummary(usage);
  const percent = piContextUsagePercentText(usage);
  const band = fraction < 0.6 ? "ok" : fraction < 0.85 ? "warn" : "danger";
  const label = [summary, percent].filter((part) => part !== null).join(" · ");
  return (
    <div className={`hz-pi-meter hz-pi-meter-${band}`}>
      <div className="hz-pi-meter-track" aria-hidden>
        <div
          className="hz-pi-meter-fill"
          style={{ width: `${Math.round(fraction * 100)}%` }}
        />
      </div>
      <span className="hz-pi-meter-text">{label}</span>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Turn
// ---------------------------------------------------------------------------

function turnFailed(turn: PiConversationTurn): boolean {
  return turn.items.some((item) => {
    if (item.kind === "assistant") {
      const status = item.value.status;
      return status !== "streaming" && status !== "complete" && status.failed;
    }
    return item.kind === "tool" && item.value.status === "failed";
  });
}

function TurnView({ turn, now }: { turn: PiConversationTurn; now: number }) {
  const failed = turnFailed(turn);
  const hasTool = turn.items.some((item) => item.kind === "tool");
  const railClass = [
    "hz-pi-rail",
    turn.isActive ? "hz-pi-rail-active" : "",
    hasTool ? "hz-pi-rail-tool" : "",
    failed ? "hz-pi-rail-failed" : "",
  ]
    .filter((part) => part !== "")
    .join(" ");

  return (
    <section className={`hz-pi-turn${failed ? " hz-pi-turn-failed" : ""}`}>
      <span className={railClass} aria-hidden />
      <div className="hz-pi-turn-body">
        {turn.user !== null && (
          <p className="hz-pi-user">{turn.user.text === "" ? "\u00A0" : turn.user.text}</p>
        )}
        {turn.items.map((item) => {
          switch (item.kind) {
            case "assistant":
              return <AssistantView key={item.value.id} text={item.value.text} status={item.value.status} />;
            case "thinking":
              return <ThinkingView key={item.value.id} block={item.value} now={now} />;
            case "tool":
              return <ToolView key={item.value.callID} tool={item.value} now={now} />;
            case "notice":
              return (
                <p
                  key={item.value.id}
                  className={`hz-pi-notice hz-pi-notice-${item.value.tone}`}
                >
                  <span className="hz-pi-notice-title">{item.value.title}</span>
                  {item.value.detail !== null && (
                    <span className="hz-pi-notice-detail">{item.value.detail}</span>
                  )}
                </p>
              );
          }
        })}
      </div>
    </section>
  );
}

function AssistantView({
  text,
  status,
}: {
  text: string;
  status: PiAssistantStatus;
}) {
  const failed = status !== "streaming" && status !== "complete" && status.failed;
  return (
    <div className={`hz-pi-assistant${failed ? " hz-pi-assistant-failed" : ""}`}>
      {failed && (
        <p className="hz-pi-assistant-error">
          Response stopped with an error
          {status.detail !== null ? ` — ${status.detail}` : ""}
        </p>
      )}
      {text !== "" && <MarkdownText text={text} />}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Thinking (collapsed disclosure; "Thinking" while streaming, "Thought
// process" when settled; byte-exact fallbacks when no reasoning text)
// ---------------------------------------------------------------------------

function ThinkingView({ block, now }: { block: PiThinkingBlock; now: number }) {
  const [open, setOpen] = useState(false);
  const hasText = block.text.trim() !== "";
  const label = block.isStreaming ? "Thinking" : "Thought process";
  const fallback =
    block.isRedacted
      ? "Reasoning details are unavailable for this response."
      : block.isStreaming && !hasText
        ? "Pi is working through the request…"
        : !hasText
          ? "No reasoning text was provided."
          : null;

  return (
    <div className={`hz-pi-thinking${open ? " hz-pi-thinking-open" : ""}`}>
      <button
        type="button"
        className="hz-pi-thinking-head"
        onClick={() => setOpen((value) => !value)}
        aria-expanded={open}
      >
        <span className="hz-pi-thinking-label">{label}</span>
        {block.isStreaming && block.startedAt !== null && (
          <span className="hz-pi-thinking-timer">{formatElapsed(now - block.startedAt)}</span>
        )}
        {fallback !== null && !open && (
          <span className="hz-pi-thinking-fallback">{fallback}</span>
        )}
      </button>
      <div className="hz-pi-thinking-body" hidden={!open}>
        {hasText ? (
          <MarkdownBlocks blocks={parsePiMarkdown(block.text)} />
        ) : (
          <p className="hz-pi-thinking-empty">{fallback}</p>
        )}
      </div>
    </div>
  );
}

function ToolView({ tool, now }: { tool: PiToolInvocation; now: number }) {
  return (
    <div className="hz-pi-tool-wrap">
      <ToolCard tool={tool} now={now} />
    </div>
  );
}

// ---------------------------------------------------------------------------
// Pane wiring (follow/stop) + store → props
// ---------------------------------------------------------------------------

export function PiChatPane() {
  const paneId = useWorkspacesStore((state) => state.selectedPaneId);

  useEffect(() => {
    if (paneId === null) return;
    const data = useWorkspacesStore.getState().data;
    const pane =
      data?.workspaces.flatMap((workspace) => workspace.panes).find((candidate) => candidate.pane_id === paneId) ??
      null;
    const semantic = pane?.pi_semantic;
    if (semantic === undefined) return;
    let capability: PiSemanticCapability;
    try {
      capability = decodePiSemanticCapability(semantic as unknown as PiJSONValue);
    } catch {
      return;
    }
    usePiStore.getState().follow(paneId, getToken(), capability);
    return () => {
      usePiStore.getState().stop(paneId);
    };
  }, [paneId]);

  const connection = usePiStore((state) => state.connection);
  const lastError = usePiStore((state) => state.lastError);
  const turns = usePiStore((state) => state.turns);
  const phase = usePiStore((state) => state.phase);
  const isTruncated = usePiStore((state) => state.isTruncated);
  const contextUsage = usePiStore((state) => state.contextUsage);
  const pendingInteractions = usePiStore((state) => state.pendingInteractions);

  return (
    <PiChatView
      connection={connection}
      lastError={lastError}
      turns={turns}
      phase={phase}
      isTruncated={isTruncated}
      contextUsage={contextUsage}
      pendingInteractions={pendingInteractions}
    />
  );
}
