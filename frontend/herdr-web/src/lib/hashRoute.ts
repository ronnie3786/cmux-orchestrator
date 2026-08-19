/**
 * Hash routing for the herdr web shell: `#ws=<workspaceId>&pane=<paneId>`
 * (both optional). Unknown params (e.g. `#deck=1` for the attention deck)
 * are preserved verbatim on round-trip.
 *
 * Pure parse/serialize helpers (unit-tested in hashRoute.test.ts); the
 * getHashRoute/setHashRoute/subscribeHash wrappers at the bottom are the
 * only pieces that touch window.location.
 */

export interface HashRoute {
  /** `#ws=` — the selected workspace (absent/empty = no selection in URL). */
  workspaceId: string | null;
  /** `#pane=` — a pane deep link inside the workspace (absent/empty = none). */
  paneId: string | null;
  /** Unknown params in original order, carried through on serialize. */
  params: Record<string, string>;
}

function decodeSafe(raw: string): string | null {
  try {
    return decodeURIComponent(raw);
  } catch {
    // Malformed percent-encoding — drop the pair.
    return null;
  }
}

export function parseHash(hash: string): HashRoute {
  const route: HashRoute = { workspaceId: null, paneId: null, params: {} };
  for (const pair of hash.replace(/^#/, "").split("&")) {
    if (!pair) continue;
    const eq = pair.indexOf("=");
    const key = decodeSafe(eq === -1 ? pair : pair.slice(0, eq));
    if (key === null || key.length === 0) continue;
    const value = decodeSafe(eq === -1 ? "" : pair.slice(eq + 1)) ?? "";
    if (key === "ws") {
      route.workspaceId = value.length > 0 ? value : null;
    } else if (key === "pane") {
      route.paneId = value.length > 0 ? value : null;
    } else if (key in route.params) {
      continue; // First occurrence wins (URLSearchParams semantics).
    } else {
      route.params[key] = value;
    }
  }
  return route;
}

export function serializeHash(route: HashRoute): string {
  const pairs: string[] = [];
  if (route.workspaceId !== null && route.workspaceId.length > 0) {
    pairs.push(`ws=${encodeURIComponent(route.workspaceId)}`);
  }
  if (route.paneId !== null && route.paneId.length > 0) {
    pairs.push(`pane=${encodeURIComponent(route.paneId)}`);
  }
  for (const [key, value] of Object.entries(route.params)) {
    pairs.push(`${encodeURIComponent(key)}=${encodeURIComponent(value)}`);
  }
  return pairs.length > 0 ? `#${pairs.join("&")}` : "";
}

/**
 * Workspace id a pane deep link belongs to: pane ids are
 * `<workspaceId>:<paneId>`, so `#pane=wB:p1` alone resolves workspace `wB`.
 * Returns null when the id has no (or a leading) colon — repairSelection
 * then falls back to the first workspace (repairNavigation parity).
 */
export function workspaceFromPaneId(paneId: string): string | null {
  const colon = paneId.indexOf(":");
  if (colon <= 0) return null;
  return paneId.slice(0, colon);
}

/** Read the current route from window.location.hash. */
export function getHashRoute(): HashRoute {
  return parseHash(window.location.hash);
}

/**
 * Write the route via history.replaceState (no history spam — the Phase-1
 * pattern). No-op when the hash already matches (echo guard).
 */
export function setHashRoute(route: HashRoute): void {
  const target = serializeHash(route);
  if (window.location.hash === target) return;
  window.history.replaceState(null, "", window.location.pathname + window.location.search + target);
}

/** Subscribe to manual hash edits / back-forward; returns an unsubscribe. */
export function subscribeHash(listener: () => void): () => void {
  window.addEventListener("hashchange", listener);
  window.addEventListener("popstate", listener);
  return () => {
    window.removeEventListener("hashchange", listener);
    window.removeEventListener("popstate", listener);
  };
}
