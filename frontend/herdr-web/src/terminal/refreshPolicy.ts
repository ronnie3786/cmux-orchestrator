/**
 * Snapshot-vs-grid arbitration — 1:1 port of
 * herdr-harness-ios/.../Models/TerminalRefreshPolicy.swift (26 lines).
 *
 * Swift rule (verbatim semantics):
 * ```
 * if streamAdvancedDuringRequest { return false }
 * if force { return true }
 * if snapshotChangedWithoutFrame { return true }
 * return isStreamStale(lastStreamActivityAt:, now:)
 * ```
 * where the stream is stale when it has never been active (nil) or has been
 * silent for ≥ 25 s (`streamSilenceLimit`).
 *
 * Dates become epoch ms; `Date?` becomes `number | null`.
 */

export const STREAM_SILENCE_LIMIT_MS = 25_000;

export interface RefreshPolicyInput {
  /** Forced snapshot (initial fetch / the toolbar refresh button). */
  force: boolean;
  /** A stream frame advanced the grid while the snapshot request was in flight. */
  streamAdvancedDuringRequest: boolean;
  /** The snapshot text changed since the previous snapshot, without grid advance. */
  snapshotChangedWithoutFrame: boolean;
  /** Epoch ms of the last stream activity, or null (never active / unknown). */
  lastStreamActivityAt: number | null;
  /** Epoch ms; defaults to Date.now() (Swift `now: Date = .now`). */
  now?: number;
}

/** Port of `shouldDisplaySnapshot(force:streamAdvancedDuringRequest:...)`. */
export function shouldDisplaySnapshot(input: RefreshPolicyInput): boolean {
  const now = input.now ?? Date.now();
  if (input.streamAdvancedDuringRequest) {
    return false;
  }
  if (input.force) {
    return true;
  }
  if (input.snapshotChangedWithoutFrame) {
    return true;
  }
  return isStreamStale(input.lastStreamActivityAt, now);
}

/** Port of `isStreamStale(lastStreamActivityAt:now:)`. */
export function isStreamStale(
  lastStreamActivityAt: number | null,
  now: number = Date.now(),
): boolean {
  if (lastStreamActivityAt === null) {
    return true;
  }
  return now - lastStreamActivityAt >= STREAM_SILENCE_LIMIT_MS;
}
