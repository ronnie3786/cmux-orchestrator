import { useEffect, useRef, useState, type CSSProperties } from "react";
import { useEscapeLayer } from "./useOverlay";

/**
 * Anchor popover plumbing shared by the pane menu (sidebar) and the
 * workspace card menu. The panel renders into document.body (fixed
 * positioning from the anchor's rect) so it is never clipped by the
 * scrollable sidebar/tree. Closes on Esc (the overlay stack) or on any
 * mousedown outside the anchor + panel.
 */
export interface PopoverControls {
  /** Attach to the ⋯ button; used for positioning. */
  anchorRef: { current: HTMLElement | null };
  /** Attach to the panel element. */
  panelRef: { current: HTMLDivElement | null };
  /** Fixed-position style for the panel (null while closed). */
  style: CSSProperties | null;
  open: boolean;
  toggle: (anchor: HTMLElement) => void;
  close: () => void;
}

const PANEL_ESTIMATE_PX = 280;
const GAP_PX = 4;
const MARGIN_PX = 8;

function positionStyle(anchor: HTMLElement): CSSProperties {
  const rect = anchor.getBoundingClientRect();
  const left = Math.max(
    MARGIN_PX,
    Math.min(rect.left, window.innerWidth - 190 - MARGIN_PX),
  );
  const fitsBelow = rect.bottom + PANEL_ESTIMATE_PX + GAP_PX <= window.innerHeight;
  const style: CSSProperties = { left, zIndex: 90 };
  if (fitsBelow) {
    style.top = rect.bottom + GAP_PX;
  } else {
    // Flip above the anchor near the bottom of the viewport.
    style.top = rect.top - GAP_PX;
    style.transform = "translateY(-100%)";
  }
  return style;
}

export function usePopover(): PopoverControls {
  const [open, setOpen] = useState(false);
  const [style, setStyle] = useState<CSSProperties | null>(null);
  const anchorRef = useRef<HTMLElement | null>(null);
  const panelRef = useRef<HTMLDivElement | null>(null);

  const close = () => setOpen(false);

  const toggle = (anchor: HTMLElement) => {
    if (open) {
      close();
      return;
    }
    anchorRef.current = anchor;
    setStyle(positionStyle(anchor));
    setOpen(true);
  };

  useEscapeLayer(close, open);

  // Outside mousedown closes (capture phase, before the panel's own
  // handlers run; the anchor's own click fires afterwards and re-opens,
  // so the toggle above must see the close first — it does, because
  // mousedown precedes click).
  useEffect(() => {
    if (!open) return;
    const onMousedown = (event: MouseEvent) => {
      const target = event.target;
      if (target instanceof Node) {
        if (panelRef.current?.contains(target) || anchorRef.current?.contains(target)) {
          return;
        }
      }
      setOpen(false);
    };
    document.addEventListener("mousedown", onMousedown, true);
    return () => document.removeEventListener("mousedown", onMousedown, true);
  }, [open]);

  return { anchorRef, panelRef, open, style, toggle, close };
}
