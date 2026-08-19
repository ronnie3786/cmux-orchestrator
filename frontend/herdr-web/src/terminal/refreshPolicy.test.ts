import { describe, expect, it } from "vitest";
import {
  STREAM_SILENCE_LIMIT_MS,
  isStreamStale,
  shouldDisplaySnapshot,
  type RefreshPolicyInput,
} from "./refreshPolicy";
import { TerminalGrid } from "./grid";
import type { TerminalFrame } from "./frame";
import deltas from "../__fixtures__/terminal-deltas.json";

const NOW = 100_000;

function input(overrides: Partial<RefreshPolicyInput> = {}): RefreshPolicyInput {
  return {
    force: false,
    streamAdvancedDuringRequest: false,
    snapshotChangedWithoutFrame: false,
    lastStreamActivityAt: NOW - 10_000, // fresh (10 s ago)
    now: NOW,
    ...overrides,
  };
}

describe("shouldDisplaySnapshot (Swift TerminalRefreshPolicy port)", () => {
  it("forced snapshot → replace", () => {
    expect(shouldDisplaySnapshot(input({ force: true }))).toBe(true);
  });

  it("grid advanced during the request → keep grid (even when forced)", () => {
    expect(
      shouldDisplaySnapshot(input({ force: true, streamAdvancedDuringRequest: true })),
    ).toBe(false);
    expect(shouldDisplaySnapshot(input({ streamAdvancedDuringRequest: true }))).toBe(false);
  });

  it("snapshot text changed without frames → replace", () => {
    expect(shouldDisplaySnapshot(input({ snapshotChangedWithoutFrame: true }))).toBe(true);
  });

  it("stream silent ≥ 25 s → replace", () => {
    expect(
      shouldDisplaySnapshot(
        input({ lastStreamActivityAt: NOW - STREAM_SILENCE_LIMIT_MS }),
      ),
    ).toBe(true);
  });

  it("stream silent < 25 s and no changes → keep grid", () => {
    expect(
      shouldDisplaySnapshot(input({ lastStreamActivityAt: NOW - STREAM_SILENCE_LIMIT_MS + 1 })),
    ).toBe(false);
  });

  it("stream never active (null) → stale → replace", () => {
    expect(shouldDisplaySnapshot(input({ lastStreamActivityAt: null }))).toBe(true);
  });
});

describe("isStreamStale", () => {
  it("null → stale", () => {
    expect(isStreamStale(null, NOW)).toBe(true);
  });

  it("≥ 25 s → stale; < 25 s → fresh", () => {
    expect(isStreamStale(NOW - 25_000, NOW)).toBe(true);
    expect(isStreamStale(NOW - 24_999, NOW)).toBe(false);
  });
});

describe("captured live delta sequence (__fixtures__/terminal-deltas.json)", () => {
  const frames = deltas as unknown as TerminalFrame[];

  it("applies full seq1 → delta seq2 → delta seq3 cleanly", () => {
    expect(frames).toHaveLength(3);
    const grid = new TerminalGrid(100, 32);
    expect(grid.apply(frames[0])).toBe(true);
    expect(grid.apply(frames[1])).toBe(true);
    expect(grid.apply(frames[2])).toBe(true);
    expect(grid.lastSequence).toBe(3);

    // Structure, not exact glyphs (the deltas are PTY-wrapped partial
    // redraws): non-empty, no replacement characters, within the viewport,
    // and every rendered run has a resolvable foreground.
    const plainText = grid.plainText;
    expect(plainText.length).toBeGreaterThan(0);
    expect(plainText).not.toContain("\uFFFD");
    const rendered = grid.visibleRows(true);
    expect(rendered.length).toBeLessThanOrEqual(32);
    for (const row of rendered) {
      for (const run of row) {
        expect(run.foreground).toBeTruthy();
      }
    }

    // A replayed stale frame (seq 2 again) is rejected and leaves state
    // untouched.
    expect(grid.apply(frames[1])).toBe(false);
    expect(grid.lastSequence).toBe(3);
    expect(grid.plainText).toBe(plainText);
  });
});
