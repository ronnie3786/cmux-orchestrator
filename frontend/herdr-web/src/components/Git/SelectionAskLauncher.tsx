import { useCallback, useEffect, useRef, useState } from "react";
import { Sparkles } from "lucide-react";
import {
  clampAnchor,
  selectionAskContext,
  type SelectionAskContext,
} from "./selectionAsk";
import { InlineAskPanel, type InlineAskAnchor } from "./InlineAskPanel";

const BUTTON_WIDTH = 108;
const BUTTON_HEIGHT = 30;
const PANEL_WIDTH = 380;
const PANEL_HEIGHT = 420;
const SELECTION_SETTLE_MS = 90;

interface FloatingAskTarget {
  anchor: InlineAskAnchor;
  context: SelectionAskContext;
}

interface SelectionAskLauncherProps {
  paneId: string;
  file: string;
  /** The scrollable diff container; Pierre's shadow DOM lives below it. */
  containerRef: React.MutableRefObject<HTMLDivElement | null>;
}

/**
 * Watches text selections inside the diff inspector. When the user
 * highlights code, a floating "Ask AI" button appears beside the selection;
 * clicking it opens the inline chat panel with the highlighted code, file,
 * and line range already attached.
 */
export function SelectionAskLauncher({ paneId, file, containerRef }: SelectionAskLauncherProps) {
  const [pending, setPending] = useState<FloatingAskTarget | null>(null);
  const [open, setOpen] = useState<FloatingAskTarget | null>(null);
  const debounceRef = useRef<number | null>(null);
  const pendingRef = useRef<FloatingAskTarget | null>(null);

  useEffect(() => {
    pendingRef.current = pending;
  }, [pending]);

  const evaluateSelection = useCallback(() => {
    const container = containerRef.current;
    if (container === null) return;
    const selection = window.getSelection();
    if (selection === null || selection.isCollapsed || selection.rangeCount === 0) {
      setPending(null);
      return;
    }
    const text = selection.toString();
    if (text.trim().length < 2 || !selectionTouches(container, selection)) {
      setPending(null);
      return;
    }
    const range = selection.getRangeAt(0);
    const rects = Array.from(range.getClientRects()).filter(
      (rect) => rect.width > 0 && rect.height > 0,
    );
    const bounds = rects.length > 0 ? rects[rects.length - 1] : range.getBoundingClientRect();
    if (bounds.width === 0 && bounds.height === 0) {
      setPending(null);
      return;
    }
    const below = bounds.bottom + 8;
    const flipUp = below + BUTTON_HEIGHT > window.innerHeight - 8;
    const anchor = clampAnchor(
      bounds.left + bounds.width / 2 - BUTTON_WIDTH / 2,
      flipUp ? bounds.top - BUTTON_HEIGHT - 8 : below,
      BUTTON_WIDTH,
      BUTTON_HEIGHT,
      window.innerWidth,
      window.innerHeight,
    );
    const diffHost = container.querySelector("diffs-container") ?? container;
    const context = selectionAskContext(diffHost, text, range);
    if (context.code === "") {
      setPending(null);
      return;
    }
    setPending({ anchor, context });
  }, [containerRef]);

  // A new file resets the conversation surface entirely.
  useEffect(() => {
    setOpen(null);
    setPending(null);
  }, [file]);

  useEffect(() => {
    const onSelectionChange = () => {
      if (debounceRef.current !== null) {
        window.clearTimeout(debounceRef.current);
      }
      debounceRef.current = window.setTimeout(() => {
        debounceRef.current = null;
        evaluateSelection();
      }, SELECTION_SETTLE_MS);
    };
    const onPointerUp = () => {
      if (debounceRef.current !== null) {
        window.clearTimeout(debounceRef.current);
        debounceRef.current = null;
      }
      // Let the selection settle before measuring, then re-check.
      debounceRef.current = window.setTimeout(() => {
        debounceRef.current = null;
        evaluateSelection();
      }, 0);
    };
    const container = containerRef.current;
    const onScroll = () => setPending(null);
    document.addEventListener("selectionchange", onSelectionChange);
    document.addEventListener("pointerup", onPointerUp);
    container?.addEventListener("scroll", onScroll, { capture: true, passive: true });
    return () => {
      if (debounceRef.current !== null) {
        window.clearTimeout(debounceRef.current);
      }
      document.removeEventListener("selectionchange", onSelectionChange);
      document.removeEventListener("pointerup", onPointerUp);
      container?.removeEventListener("scroll", onScroll, { capture: true } as EventListenerOptions);
    };
  }, [containerRef, evaluateSelection]);

  // Hide the floating button whenever the panel is open.
  useEffect(() => {
    if (open !== null) setPending(null);
  }, [open]);

  const openPanel = useCallback(() => {
    const current = pendingRef.current;
    if (current === null) return;
    setPending(null);
    setOpen({
      anchor: clampAnchor(
        current.anchor.left,
        current.anchor.top,
        PANEL_WIDTH,
        PANEL_HEIGHT,
        window.innerWidth,
        window.innerHeight,
      ),
      context: current.context,
    });
  }, []);

  return (
    <>
      {pending !== null ? (
        <button
          type="button"
          className="hz-inline-ask-launcher"
          style={{ left: pending.anchor.left, top: pending.anchor.top }}
          onMouseDown={(event) => event.preventDefault()}
          onClick={openPanel}
        >
          <Sparkles size={13} aria-hidden />
          <span>Ask AI</span>
        </button>
      ) : null}
      {open !== null ? (
        <InlineAskPanel
          paneId={paneId}
          file={file}
          context={open.context}
          anchor={open.anchor}
          onClose={() => setOpen(null)}
        />
      ) : null}
    </>
  );
}

/**
 * True when the selection's nodes belong to the container's light DOM or to a
 * shadow root the container hosts (Pierre renders inside one).
 */
function selectionTouches(container: HTMLElement, selection: Selection): boolean {
  const anchor = selection.anchorNode;
  const focus = selection.focusNode;
  if (anchor === null || focus === null) return false;
  return nodeTouches(container, anchor) && nodeTouches(container, focus);
}

function nodeTouches(container: HTMLElement, node: Node): boolean {
  if (container.contains(node)) return true;
  const root = node.getRootNode();
  return root instanceof ShadowRoot && container.contains(root.host);
}