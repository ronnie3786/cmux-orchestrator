import { useEffect, useRef } from "react";

/**
 * Overlay hygiene hooks (Phase 7 polish pass).
 *
 * - `useEscapeLayer`: a single window keydown listener + a stack of escape
 *   handlers. Only the most recently registered (top-most) layer handles
 *   Escape, so stacked overlays (a dialog opened over a menu) close one at
 *   a time with no double handling. Replaces the per-overlay window
 *   listeners that each closed on every Esc press.
 *
 * - `useScrollLock`: hides body scroll while an overlay is open (reference
 *   counted so stacked overlays unlock only when the last one closes).
 *   The app layout is a fixed-height grid with inner scrollers, so this
 *   mostly guards keyboard/overscroll chaining on the page behind the
 *   backdrop.
 */

type EscapeHandler = (event: KeyboardEvent) => void;

let escapeStack: Array<{ id: number; handler: EscapeHandler }> = [];
let nextLayerId = 0;
let escapeListenerInstalled = false;

function onWindowKeydown(event: KeyboardEvent) {
  if (event.key !== "Escape") return;
  const top = escapeStack[escapeStack.length - 1];
  if (top === undefined) return;
  // Consume the event so lower layers and page-level Esc behavior (e.g. the
  // input bar blur shortcut) don't fire as well.
  event.preventDefault();
  event.stopPropagation();
  top.handler(event);
}

/**
 * Register `onEscape` as the top-most Escape layer while `enabled`.
 *
 * The callback is kept in a ref, so the layer registration is stable across
 * renders (a re-render with a new closure does not reshuffle the stack).
 * The layer still consumes Escape while mounted — e.g. the new-session
 * modal blocks lower layers while a creation is in flight even though it
 * deliberately does nothing with the key.
 */
export function useEscapeLayer(onEscape: EscapeHandler, enabled: boolean = true): void {
  const callbackRef = useRef(onEscape);
  callbackRef.current = onEscape;

  useEffect(() => {
    if (!enabled) return;
    const id = ++nextLayerId;
    const layer = { id, handler: (event: KeyboardEvent) => callbackRef.current(event) };
    escapeStack.push(layer);
    if (!escapeListenerInstalled) {
      escapeListenerInstalled = true;
      // Capture phase: run before React's delegated listeners (the input bar
      // textarea Esc handler) so a top-most overlay wins deterministically.
      window.addEventListener("keydown", onWindowKeydown, true);
    }
    return () => {
      const index = escapeStack.findIndex((entry) => entry.id === id);
      if (index !== -1) escapeStack.splice(index, 1);
      if (escapeStack.length === 0 && escapeListenerInstalled) {
        window.removeEventListener("keydown", onWindowKeydown, true);
        escapeListenerInstalled = false;
      }
    };
  }, [enabled]);
}

let scrollLockCount = 0;
let previousOverflow: string | null = null;

/** Lock body scroll while `active` (reference counted). */
export function useScrollLock(active: boolean): void {
  useEffect(() => {
    if (!active) return;
    if (scrollLockCount === 0) {
      previousOverflow = document.body.style.overflow;
      document.body.style.overflow = "hidden";
    }
    scrollLockCount += 1;
    return () => {
      scrollLockCount -= 1;
      if (scrollLockCount === 0 && previousOverflow !== null) {
        document.body.style.overflow = previousOverflow;
        previousOverflow = null;
      }
    };
  }, [active]);
}
