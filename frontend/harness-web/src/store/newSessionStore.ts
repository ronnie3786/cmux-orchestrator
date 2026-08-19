import { create } from "zustand";
import { newSession } from "../api/endpoints";
import { jiraKey } from "../lib/jiraKey";
import { workspaceID } from "../lib/workspaceGroups";
import { useConnectionStore } from "./connectionStore";
import type { Workspace } from "../api/types";

/**
 * New-session modal + success flow. Ports the iOS `NewSessionView` form
 * (SettingsNewSessionViews.swift) and the quick-creation success flow
 * (HarnessFeatureConnectionReducer.refreshSucceeded +
 * SessionCreationProgressOverlay).
 *
 * Request mapping is exactly iOS `HarnessAPI.createSession`:
 * - shell:  { projectPath, branchName: "", jiraUrl: "", prompt: "", command: "zsh",    sessionName: name }
 * - claude: { projectPath, branchName, jiraUrl, prompt, command: "claude", sessionName: "" }
 *
 * Success: the modal closes, the overlay enters `switching`, a catch-up
 * status refresh is requested after 750 ms (iOS parity), and the created
 * workspace is auto-selected as soon as it appears in a status poll
 * (matched by uuid, then index — iOS `matchingWorkspaceID`).
 */

export type NewSessionMode = "claude" | "shell";
export type NewSessionPhase = "idle" | "creating" | "switching";

const DEFAULT_PROJECT_PATH = "~/Documents/Development/sample-app";
const CATCH_UP_REFRESH_MS = 750;

interface PendingSelection {
  uuid: string | null;
  index: number | null;
}

interface NewSessionState {
  isOpen: boolean;
  mode: NewSessionMode;
  projectPath: string;
  branchName: string;
  jiraUrl: string;
  prompt: string;
  /** Shell-mode session name (iOS "Name" field, default "Shell"). */
  sessionName: string;
  error: string | null;
  phase: NewSessionPhase;
  pendingSelection: PendingSelection | null;
  /** Project path shown (abbreviated) by the progress overlay. */
  overlayDirectory: string | null;

  open: () => void;
  close: () => void;
  cancel: () => void;
  setMode: (mode: NewSessionMode) => void;
  setProjectPath: (value: string) => void;
  setBranchName: (value: string) => void;
  setJiraUrl: (value: string) => void;
  setPrompt: (value: string) => void;
  setSessionName: (value: string) => void;
  submit: () => Promise<void>;
  /** iOS `matchingWorkspaceID`: uuid first, then index. */
  resolvePendingSelection: (workspaces: Workspace[]) => string | null;
  finishSelection: () => void;
}

const DEFAULT_FORM = {
  mode: "claude" as NewSessionMode,
  projectPath: DEFAULT_PROJECT_PATH,
  branchName: "",
  jiraUrl: "",
  prompt: "",
  sessionName: "Shell",
};

export const useNewSessionStore = create<NewSessionState>()((set, get) => ({
  isOpen: false,
  ...DEFAULT_FORM,
  error: null,
  phase: "idle",
  pendingSelection: null,
  overlayDirectory: null,

  // iOS `newSessionButtonTapped`: resets the form and cancels any in-flight
  // quick-creation overlay.
  open: () => {
    set({ ...DEFAULT_FORM, isOpen: true, error: null, phase: "idle", pendingSelection: null, overlayDirectory: null });
  },

  close: () => {
    if (get().phase === "creating") return;
    set({ isOpen: false, error: null });
  },

  // Cancel is blocked while the request is in flight (the server will create
  // the worktree either way; iOS keeps the button busy-disabled).
  cancel: () => {
    get().close();
  },

  setMode: (mode) => {
    if (get().phase === "creating") return;
    set({ mode });
  },

  setProjectPath: (value) => {
    if (get().phase === "creating") return;
    set({ projectPath: value });
  },

  setBranchName: (value) => {
    if (get().phase === "creating") return;
    set({ branchName: value });
  },

  // iOS `newSessionJiraChanged`: auto-fill the branch from the URL only while
  // the branch field is empty.
  setJiraUrl: (value) => {
    if (get().phase === "creating") return;
    const key = jiraKey(value);
    set({
      jiraUrl: value,
      ...(key && get().branchName === "" ? { branchName: key } : {}),
    });
  },

  setPrompt: (value) => {
    if (get().phase === "creating") return;
    set({ prompt: value });
  },

  setSessionName: (value) => {
    if (get().phase === "creating") return;
    set({ sessionName: value });
  },

  submit: async () => {
    const state = get();
    if (state.phase === "creating") return;
    if (state.projectPath.trim().length === 0) {
      // iOS guard: "Project path is required."
      set({ error: "Project path is required." });
      return;
    }

    const isShell = state.mode === "shell";
    // iOS client: trimmedName = sessionName.trimmed; trimmedName.isEmpty ? "Shell" : trimmedName.
    const trimmedSessionName = state.sessionName.trim();
    set({ phase: "creating", error: null });
    try {
      const response = await newSession({
        projectPath: state.projectPath,
        branchName: isShell ? "" : state.branchName,
        jiraUrl: isShell ? "" : state.jiraUrl,
        prompt: isShell ? "" : state.prompt,
        command: isShell ? "zsh" : "claude",
        sessionName: isShell ? (trimmedSessionName === "" ? "Shell" : trimmedSessionName) : "",
      });

      const created = response.workspace ?? null;
      // iOS: success → isShowingNewSession = false, quickSessionCreation =
      // (.switching), then refresh 750 ms later.
      set({
        isOpen: false,
        phase: "switching",
        pendingSelection: created ? { uuid: created.uuid ?? null, index: created.index ?? null } : null,
        overlayDirectory: state.projectPath,
      });
      setTimeout(() => {
        useConnectionStore.getState().requestTick();
      }, CATCH_UP_REFRESH_MS);
    } catch (err) {
      // iOS `createNewSessionFailed`: modal stays open with the error string.
      set({
        phase: "idle",
        pendingSelection: null,
        overlayDirectory: null,
        isOpen: true,
        error: err instanceof Error ? err.message : "Session creation failed.",
      });
    }
  },

  resolvePendingSelection: (workspaces) => {
    const selection = get().pendingSelection;
    if (!selection) return null;
    const match =
      (selection.uuid && workspaces.find((w) => w.uuid === selection.uuid)) ||
      (selection.index != null && workspaces.find((w) => w.index === selection.index));
    return match ? workspaceID(match) : null;
  },

  finishSelection: () => {
    set({ phase: "idle", pendingSelection: null, overlayDirectory: null });
  },
}));
