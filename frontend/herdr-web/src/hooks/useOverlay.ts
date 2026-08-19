import { useEffect, useRef } from "react";

/**
 * Overlay hygiene hooks (direct port of the Phase-1 harness-web hook).
 *
 * - `useEscapeLayer`: a single window keydown listener + a stack of escape
 *   handlers. Only the most recently registered (top-most) layer handles
 *   Escape, so stacked overlays (a dialog opened over the drawer) close one
 *   at a time with no double handling.
 *
 * - `useScrollLock`: hides body scroll while an overlay is open (reference
 *   counted so stacked overlays unlock only when the last one closes).
 */

type EscapeHandler = (event: KeyboardEvent) => void;

let escapeStack: Array<{ id: number; handler: EscapeHandler }> = [];
let nextLayerId = 0;
let escapeListenerInstalled = false;

function onWindowKeydown(event: KeyboardEvent) {
  if (event.key !== "Escape") return;
  const top = escapeStack[escapeStack.length - 1];
  if (top === undefined) return;
  // Consume the event so lower layers and page-level Esc behavior don't fire
  // as well.
  event.preventDefault();
  event.stopPropagation();
  top.handler(event);
}

/**
 * Register `onEscape` as the top-most Escape layer while `enabled`.
 *
 * The callback is kept in a ref, so the layer registration is stable across
 * renders (a re-render with a new closure does not reshuffle the stack).
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
      // Capture phase: run before React's delegated listeners so a top-most
      // overlay wins deterministically.
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
