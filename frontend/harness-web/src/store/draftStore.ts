import { create } from "zustand";
import { appendPromptBlock, appendPromptToken } from "../lib/reviewPrompt";

/**
 * Per-workspace detail input drafts (iOS `detailDrafts` / `persistDetailDraft`
 * parity). Keyed by the selected workspace row id (uuid, or `uuid|surfaceId`
 * for multi-surface rows — the same id `workspacesStore` uses for selection).
 *
 * Persistence: `harness-web:draft:<id>` in localStorage, mirroring the iOS
 * app's per-workspace draft persistence. This is the plumbing Phase 4's full
 * input bar (attachments etc.) builds on.
 */

const DRAFT_KEY_PREFIX = "harness-web:draft:";

function draftKey(id: string): string {
  return DRAFT_KEY_PREFIX + id;
}

function storage(): Storage | null {
  try {
    const s = (globalThis as { localStorage?: Storage }).localStorage;
    return s ?? null;
  } catch {
    return null;
  }
}

function persistDraft(id: string, value: string): void {
  const store = storage();
  if (!store) return;
  try {
    // iOS parity: an empty draft removes the persisted entry.
    if (value === "") {
      store.removeItem(draftKey(id));
    } else {
      store.setItem(draftKey(id), value);
    }
  } catch {
    // Storage full/unavailable — drafts stay in memory.
  }
}

function loadPersistedDrafts(): Record<string, string> {
  const store = storage();
  const drafts: Record<string, string> = {};
  if (!store) return drafts;
  try {
    for (let i = 0; i < store.length; i += 1) {
      const key = store.key(i);
      if (!key || !key.startsWith(DRAFT_KEY_PREFIX)) continue;
      const value = store.getItem(key);
      if (value) {
        drafts[key.slice(DRAFT_KEY_PREFIX.length)] = value;
      }
    }
  } catch {
    // Ignore — start with an empty draft map.
  }
  return drafts;
}

interface DraftStoreState {
  /** All loaded drafts, keyed by workspace row id. */
  drafts: Record<string, string>;
  /** Workspace row id bound to the input row (null before first selection). */
  activeDraftID: string | null;
  /** The draft text currently shown in the input row. */
  activeDraft: string;
  /**
   * Monotonic focus request counter (iOS `detailInputFocusRequest`). The input
   * row focuses when it observes a change, then marks the request handled.
   */
  focusRequest: number;

  /** iOS `loadDetailDraft` — bind the input row to a workspace's draft. */
  selectDraft: (id: string) => void;
  /** Update + persist the active draft. */
  setDraft: (value: string) => void;
  /** iOS `appendPromptBlock` into the active draft + persist. */
  appendBlock: (block: string) => void;
  /** iOS `appendPromptToken` into the active draft + persist (file/skill inserts). */
  appendToken: (token: string) => void;
  /** Clear the active draft (removes the persisted entry, iOS parity). */
  clearDraft: () => void;
  /** iOS `trimDrafts` — drop drafts for workspaces that no longer exist. */
  trimDrafts: (activeIDs: string[]) => void;
  /** Bump the input focus request (iOS `detailInputFocusRequest += 1`). */
  requestFocus: () => void;
  /** iOS `detailInputFocusHandled` — only the current request clears it. */
  markFocusHandled: (request: number) => void;
}

let draftsLoaded = false;

/** Lazily hydrate persisted drafts on first use (safe in node/test envs). */
function ensureDraftsLoaded(): Record<string, string> {
  if (draftsLoaded) {
    return useDraftStore.getState().drafts;
  }
  const drafts = loadPersistedDrafts();
  draftsLoaded = true;
  useDraftStore.setState({ drafts });
  return drafts;
}

export const useDraftStore = create<DraftStoreState>()((set, get) => ({
  drafts: {},
  activeDraftID: null,
  activeDraft: "",
  focusRequest: 0,

  selectDraft: (id) => {
    const drafts = ensureDraftsLoaded();
    set({ activeDraftID: id, activeDraft: drafts[id] ?? "" });
  },

  setDraft: (value) => {
    const id = get().activeDraftID;
    if (id === null) {
      set({ activeDraft: value });
      return;
    }
    const drafts = { ...get().drafts, [id]: value };
    persistDraft(id, value);
    set({ drafts, activeDraft: value });
  },

  appendBlock: (block) => {
    const id = get().activeDraftID;
    if (id === null) return;
    get().setDraft(appendPromptBlock(block, get().activeDraft));
  },

  appendToken: (token) => {
    const id = get().activeDraftID;
    if (id === null) return;
    get().setDraft(appendPromptToken(token, get().activeDraft));
  },

  clearDraft: () => {
    const id = get().activeDraftID;
    if (id === null) {
      set({ activeDraft: "" });
      return;
    }
    const drafts = { ...get().drafts };
    delete drafts[id];
    persistDraft(id, "");
    set({ drafts, activeDraft: "" });
  },

  trimDrafts: (activeIDs) => {
    const active = new Set(activeIDs);
    const current = get().drafts;
    const stale = Object.keys(current).filter((id) => !active.has(id));
    if (stale.length === 0) return;
    const drafts = { ...current };
    for (const id of stale) {
      delete drafts[id];
      persistDraft(id, "");
    }
    set({ drafts });
  },

  requestFocus: () => set({ focusRequest: get().focusRequest + 1 }),

  markFocusHandled: (request) => {
    if (get().focusRequest === request) {
      set({ focusRequest: 0 });
    }
  },
}));
