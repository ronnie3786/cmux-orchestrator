import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { TOAST_DURATION_MS, useToastStore } from "./toast";

beforeEach(() => {
  useToastStore.setState({ message: null });
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("TOAST_DURATION_MS", () => {
  it("matches the iOS ToastView auto-dismiss window (2.2 s)", () => {
    expect(TOAST_DURATION_MS).toBe(2200);
  });
});

describe("toast auto-dismiss", () => {
  it("dismisses after 2.2 s and holds until the last millisecond", () => {
    useToastStore.getState().showToast("Pane closed");
    vi.advanceTimersByTime(TOAST_DURATION_MS - 1);
    expect(useToastStore.getState().message).toBe("Pane closed");
    vi.advanceTimersByTime(1);
    expect(useToastStore.getState().message).toBeNull();
  });

  it("manual dismiss clears the message and its pending timer", () => {
    useToastStore.getState().showToast("Pane closed");
    useToastStore.getState().dismiss();
    expect(useToastStore.getState().message).toBeNull();
    // No timer left behind: nothing can re-set the message.
    vi.advanceTimersByTime(TOAST_DURATION_MS * 2);
    expect(useToastStore.getState().message).toBeNull();
  });

  it("a new toast resets the auto-dismiss clock", () => {
    useToastStore.getState().showToast("First");
    vi.advanceTimersByTime(TOAST_DURATION_MS - 100);
    useToastStore.getState().showToast("Second");
    // "First"'s clock was cleared: "Second" gets a full 2.2 s.
    vi.advanceTimersByTime(TOAST_DURATION_MS - 100);
    expect(useToastStore.getState().message).toBe("Second");
    vi.advanceTimersByTime(100);
    expect(useToastStore.getState().message).toBeNull();
  });
});
