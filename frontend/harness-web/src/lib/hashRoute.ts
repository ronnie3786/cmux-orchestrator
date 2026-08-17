/**
 * Hash routing for session deep links: `#/sessions/<id>`.
 *
 * Pure parse/serialize helpers (unit-tested); the React wiring lives in
 * `hooks/useSessionHashRoute.ts`. The encoded id is the app's workspace row
 * id (a session uuid, or `uuid|surfaceId` for multi-pane rows) so a deep link
 * restores the exact pane selection.
 */

const HASH_PREFIX = "#/sessions/";

/** Parse a `location.hash` value into a session row id, or null when absent. */
export function parseSessionHash(hash: string): string | null {
  if (!hash.startsWith(HASH_PREFIX)) return null;
  const raw = hash.slice(HASH_PREFIX.length);
  if (raw.length === 0) return null;
  try {
    const decoded = decodeURIComponent(raw);
    return decoded.length > 0 ? decoded : null;
  } catch {
    // Malformed percent-encoding — treat as no session.
    return null;
  }
}

/** Serialize a row id back to a hash ("" = no session selected). */
export function serializeSessionHash(rowID: string | null): string {
  if (rowID == null || rowID.length === 0) return "";
  return `${HASH_PREFIX}${encodeURIComponent(rowID)}`;
}
