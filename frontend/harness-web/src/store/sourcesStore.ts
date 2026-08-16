import { create } from "zustand";

/**
 * Saved server sources for the Settings sheet. Mirrors the iOS
 * `HarnessSettingsStore` server-source model (name + URL pairs with a
 * selected source), persisted in localStorage under `harness-web:sources`.
 * Informational on web: the app is always served by the server it talks to.
 */

export interface ServerSource {
  id: string;
  name: string;
  url: string;
}

const SOURCES_KEY = "harness-web:sources";
const ACTIVE_SOURCE_KEY = "harness-web:activeSourceId";

interface SourcesState {
  sources: ServerSource[];
  /** Effective active source id (falls back to the first saved source, iOS parity). */
  activeId: string | null;
  addSource: (name: string, url: string) => string | null;
  deleteSource: (id: string) => void;
  selectSource: (id: string) => void;
}

function isServerSource(value: unknown): value is ServerSource {
  if (!value || typeof value !== "object") return false;
  const v = value as Record<string, unknown>;
  return typeof v.id === "string" && typeof v.name === "string" && typeof v.url === "string";
}

function loadSources(): ServerSource[] {
  try {
    const raw = localStorage.getItem(SOURCES_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(isServerSource).map((s) => ({ id: s.id, name: s.name, url: s.url }));
  } catch {
    return [];
  }
}

function loadStoredActiveId(): string | null {
  try {
    return localStorage.getItem(ACTIVE_SOURCE_KEY);
  } catch {
    return null;
  }
}

function persistSources(sources: ServerSource[], activeId: string | null) {
  try {
    localStorage.setItem(SOURCES_KEY, JSON.stringify(sources));
    if (activeId) {
      localStorage.setItem(ACTIVE_SOURCE_KEY, activeId);
    } else {
      localStorage.removeItem(ACTIVE_SOURCE_KEY);
    }
  } catch {
    // Storage unavailable (private mode) — sources just won't persist.
  }
}

/** iOS `selectedServerSourceID` getter: stored id when valid, else first source. */
function effectiveActiveId(sources: ServerSource[], stored: string | null): string | null {
  if (stored && sources.some((s) => s.id === stored)) return stored;
  return sources.length > 0 ? sources[0].id : null;
}

function newSourceId(): string {
  return typeof crypto !== "undefined" && "randomUUID" in crypto
    ? crypto.randomUUID()
    : `source-${Date.now()}`;
}

export const useSourcesStore = create<SourcesState>()((set, getState) => ({
  ...initial(),

  addSource: (name, url) => {
    const trimmedUrl = url.trim();
    if (trimmedUrl.length === 0) {
      return "Server URL is required.";
    }
    const source: ServerSource = { id: newSourceId(), name: name.trim(), url: trimmedUrl };
    const sources = [...getState().sources, source];
    // iOS `saveServerTapped` → `activateServerSource`: a newly saved source
    // becomes the selected one.
    persistSources(sources, source.id);
    set({ sources, activeId: source.id });
    return null;
  },

  deleteSource: (id) => {
    const { sources, activeId } = getState();
    const next = sources.filter((s) => s.id !== id);
    const nextActive = effectiveActiveId(next, activeId === id ? null : activeId);
    persistSources(next, nextActive);
    set({ sources: next, activeId: nextActive });
  },

  selectSource: (id) => {
    const { sources } = getState();
    if (!sources.some((s) => s.id === id)) return;
    persistSources(sources, id);
    set({ activeId: id });
  },
}));

function initial(): { sources: ServerSource[]; activeId: string | null } {
  const sources = loadSources();
  return { sources, activeId: effectiveActiveId(sources, loadStoredActiveId()) };
}
