/**
 * Tiny toast helper (iOS ToastView parity: single top-of-screen toast,
 * auto-dismiss after 2.2 s). The host component (components/Toast) renders
 * the current message with role="status".
 */

import { create } from "zustand";

/** iOS ToastView auto-dismiss window. */
export const TOAST_DURATION_MS = 2_200;

interface ToastState {
  message: string | null;
  showToast: (message: string) => void;
  dismiss: () => void;
}

let timer: ReturnType<typeof setTimeout> | null = null;

function clearTimer(): void {
  if (timer !== null) {
    clearTimeout(timer);
    timer = null;
  }
}

export const useToastStore = create<ToastState>()((set) => ({
  message: null,
  showToast: (message) => {
    clearTimer();
    set({ message });
    timer = setTimeout(() => {
      timer = null;
      set({ message: null });
    }, TOAST_DURATION_MS);
  },
  dismiss: () => {
    clearTimer();
    set({ message: null });
  },
}));

/** Imperative entry point (fires from buttons/menus without store imports). */
export function showToast(message: string): void {
  useToastStore.getState().showToast(message);
}
