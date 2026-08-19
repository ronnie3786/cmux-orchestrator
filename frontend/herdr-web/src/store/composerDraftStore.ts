/**
 * Per-pane composer draft (P11-run-B) — lifted out of PromptComposerView
 * local state because each pane view (Terminal / Git / Skills) mounts its
 * own CommandLensDock: a skill insert made in the Skills view must survive
 * the skills → terminal view switch. iOS keeps the draft at model level
 * per pane; this is the web analog.
 */

import { create } from "zustand";

interface ComposerDraftStoreState {
  drafts: Record<string, string>;
  setDraft: (paneId: string, update: (draft: string) => string) => void;
}

export const useComposerDraftStore = create<ComposerDraftStoreState>()((set) => ({
  drafts: {},
  setDraft: (paneId, update) =>
    set((state) => ({
      drafts: { ...state.drafts, [paneId]: update(state.drafts[paneId] ?? "") },
    })),
}));
