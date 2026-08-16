/**
 * Per-workspace terminal attachments (iOS `terminalAttachments` state +
 * HarnessFeatureAttachmentsReducer + uploadAttachmentEffect parity).
 *
 * Keyed by the workspace row id (the same id draftStore uses — `uuid`, or
 * `uuid|surfaceId` for multi-surface rows). Uploads are raw-body POSTs to
 * /api/attachments via endpoints.uploadAttachment (X-Cmux-* headers, 60 s
 * timeout). Client-side guards mirror HarnessAPI.uploadAttachment: empty file
 * and the 20 MB cap are rejected before any network call.
 *
 * State machine per attachment:
 *   uploading --success--> added (serverPath set, error cleared)
 *   uploading --failure--> error (message set)
 *   error --retry()------> uploading (serverPath/error cleared, re-upload)
 *   any --remove()--------> (record dropped; a late upload result is a no-op,
 *                          exactly like the iOS firstIndex-guarded reducers)
 */

import { create } from "zustand";
import { uploadAttachment } from "../api/endpoints";
import { useConnectionStore } from "./connectionStore";

/** iOS HarnessAPI.attachmentMaxBytes: 20 MB. */
export const ATTACHMENT_MAX_BYTES = 20 * 1024 * 1024;

export type AttachmentStatus = "uploading" | "added" | "error";

export interface Attachment {
  id: string;
  /** Display name (iOS TerminalAttachment.filename). */
  name: string;
  /** Source size in bytes. */
  size: number;
  /** Source mime type (File.type; "" when unknown). */
  mime: string;
  state: AttachmentStatus;
  /** Server-stored absolute path (uploaded.path) once added. */
  serverPath?: string;
  /** Failure message for the error state (iOS TerminalAttachment.error). */
  error?: string;
  /** In-memory source: the picker File, or the voice-note Blob as a File. */
  file: Blob;
  /** Upload target captured at add time — keeps retry() self-contained. */
  targetIndex: number;
  targetUUID: string;
}

/** The workspace an upload targets (index + UUID for the X-Cmux-* headers). */
export interface AttachmentUploadTarget {
  index: number;
  uuid?: string | null;
}

/** Resolves to the server-stored path (uploaded.path). */
export type AttachmentUploadFn = (attachment: Attachment) => Promise<string>;

/** iOS HarnessAPI.uploadAttachment client guards: empty / over the 20 MB cap. */
export function attachmentSizeError(size: number): string | null {
  if (size <= 0) return "File is empty";
  if (size > ATTACHMENT_MAX_BYTES) return "File exceeds 20 MB limit";
  return null;
}

const defaultUploadFn: AttachmentUploadFn = async (attachment) => {
  const sizeError = attachmentSizeError(attachment.size);
  if (sizeError) throw new Error(sizeError);
  const response = await uploadAttachment({
    index: attachment.targetIndex,
    uuid: attachment.targetUUID === "" ? null : attachment.targetUUID,
    filename: attachment.name,
    data: attachment.file,
    contentType: attachment.mime === "" ? undefined : attachment.mime,
  });
  const path = (response.attachment?.path ?? "").trim();
  if (path.length === 0) throw new Error("Attachment upload failed");
  return path;
};

/**
 * Test seam: stub the upload transport (null restores the real
 * POST /api/attachments path). Mirrors how the store tests exercise the iOS
 * effects with a fake client.
 */
let uploadFn: AttachmentUploadFn = defaultUploadFn;

export function setAttachmentUploadFn(fn: AttachmentUploadFn | null): void {
  uploadFn = fn === null ? defaultUploadFn : fn;
}

let idCounter = 0;

function makeAttachmentID(): string {
  const crypto = (globalThis as { crypto?: { randomUUID?: () => string } }).crypto;
  if (crypto?.randomUUID) return crypto.randomUUID();
  idCounter += 1;
  return `attachment-${Date.now()}-${idCounter}`;
}

interface AttachmentsStoreState {
  /** All attachments, keyed by workspace row id. */
  byWorkspace: Record<string, Attachment[]>;
  /** Workspace row id bound to the input row (null before first selection). */
  activeWorkspaceID: string | null;

  /** Bind the input row to a workspace's attachments (iOS loadDetailDraft analog). */
  selectWorkspace: (id: string) => void;
  /**
   * iOS attachmentFilesPicked: append one `uploading` record per file and
   * start an uploadAttachmentEffect for each.
   */
  addFiles: (files: File[], workspaceID: string, target: AttachmentUploadTarget) => void;
  /** iOS removeAttachment — drop a record from the active workspace. */
  remove: (id: string) => void;
  /** iOS retryAttachment — re-upload from the error state. */
  retry: (id: string) => void;
  /** Clear the active workspace's attachments (iOS sendDetailDraft clears them on send). */
  clearActive: () => void;
  /** iOS trimDrafts analog — drop attachments for workspaces that no longer exist. */
  trim: (activeIDs: string[]) => void;
}

type SetState = (
  partial:
    | Partial<AttachmentsStoreState>
    | ((state: AttachmentsStoreState) => Partial<AttachmentsStoreState>),
) => void;
type GetState = () => AttachmentsStoreState;

/**
 * Patch one record. No-op when the record is gone (removed while an upload
 * was in flight — the same guard the iOS reducers have on firstIndex).
 */
function patchAttachment(
  set: SetState,
  workspaceID: string,
  id: string,
  patch: Partial<Attachment>,
): void {
  set((state) => {
    const list = state.byWorkspace[workspaceID];
    if (!list) return {};
    const index = list.findIndex((attachment) => attachment.id === id);
    if (index === -1) return {};
    const next = [...list];
    next[index] = { ...next[index], ...patch };
    return { byWorkspace: { ...state.byWorkspace, [workspaceID]: next } };
  });
}

/** Port of uploadAttachmentEffect: run the upload, route success/failure. */
function runUpload(set: SetState, get: GetState, workspaceID: string, id: string): void {
  void (async () => {
    const list = get().byWorkspace[workspaceID] ?? [];
    const attachment = list.find((candidate) => candidate.id === id);
    if (!attachment) return;
    try {
      const serverPath = await uploadFn(attachment);
      // iOS attachmentUploadSucceeded: mark added + clear the error banner.
      patchAttachment(set, workspaceID, id, {
        state: "added",
        serverPath,
        error: undefined,
      });
      useConnectionStore.getState().clearError();
    } catch (error) {
      // iOS attachmentUploadFailed: per-attachment error, upload continues for
      // the other files (each has its own effect).
      const message =
        error instanceof Error && error.message.length > 0 ? error.message : "Upload failed";
      patchAttachment(set, workspaceID, id, { state: "error", error: message });
    }
  })();
}

export const useAttachmentsStore = create<AttachmentsStoreState>()((set, get) => ({
  byWorkspace: {},
  activeWorkspaceID: null,

  selectWorkspace: (id) => set({ activeWorkspaceID: id }),

  addFiles: (files, workspaceID, target) => {
    if (files.length === 0) return;
    const attachments: Attachment[] = files.map((file) => ({
      id: makeAttachmentID(),
      name: file.name === "" ? "attachment" : file.name,
      size: file.size,
      mime: file.type,
      state: "uploading",
      file,
      targetIndex: target.index,
      targetUUID: target.uuid ?? "",
    }));
    set((state) => ({
      byWorkspace: {
        ...state.byWorkspace,
        [workspaceID]: [...(state.byWorkspace[workspaceID] ?? []), ...attachments],
      },
    }));
    for (const attachment of attachments) {
      runUpload(set, get, workspaceID, attachment.id);
    }
  },

  remove: (id) => {
    const workspaceID = get().activeWorkspaceID;
    if (workspaceID === null) return;
    set((state) => {
      const list = state.byWorkspace[workspaceID];
      if (!list) return {};
      const next = list.filter((attachment) => attachment.id !== id);
      if (next.length === list.length) return {};
      const byWorkspace = { ...state.byWorkspace };
      if (next.length === 0) delete byWorkspace[workspaceID];
      else byWorkspace[workspaceID] = next;
      return { byWorkspace };
    });
  },

  retry: (id) => {
    const workspaceID = get().activeWorkspaceID;
    if (workspaceID === null) return;
    const list = get().byWorkspace[workspaceID] ?? [];
    const attachment = list.find((candidate) => candidate.id === id);
    if (!attachment) return;
    patchAttachment(set, workspaceID, id, {
      state: "uploading",
      serverPath: undefined,
      error: undefined,
    });
    runUpload(set, get, workspaceID, id);
  },

  clearActive: () => {
    const workspaceID = get().activeWorkspaceID;
    if (workspaceID === null) return;
    set((state) => {
      if (!state.byWorkspace[workspaceID]) return {};
      const byWorkspace = { ...state.byWorkspace };
      delete byWorkspace[workspaceID];
      return { byWorkspace };
    });
  },

  trim: (activeIDs) => {
    const active = new Set(activeIDs);
    const current = get().byWorkspace;
    const stale = Object.keys(current).filter((id) => !active.has(id));
    if (stale.length === 0) return;
    const byWorkspace = { ...current };
    for (const id of stale) delete byWorkspace[id];
    set({ byWorkspace });
  },
}));

/** Stable empty list — keeps the selector result referentially stable. */
const EMPTY_ATTACHMENTS: Attachment[] = [];

/**
 * The active workspace's attachments. Stable reference for zustand selectors
 * (a fresh `[]` per call would re-render on every unrelated store change).
 */
export function activeAttachmentsOf(
  state: Pick<AttachmentsStoreState, "byWorkspace" | "activeWorkspaceID">,
): Attachment[] {
  const id = state.activeWorkspaceID;
  return id === null ? EMPTY_ATTACHMENTS : (state.byWorkspace[id] ?? EMPTY_ATTACHMENTS);
}

/** Number of in-flight uploads (iOS uses this to gate the send button). */
export function inFlightCount(attachments: Attachment[]): number {
  return attachments.reduce((count, attachment) => count + (attachment.state === "uploading" ? 1 : 0), 0);
}

/**
 * Server paths ready for the next send — iOS
 * `attachments.compactMap { $0.uploadedPath }`.
 */
export function uploadedPaths(attachments: Attachment[]): string[] {
  return attachments
    .filter((attachment) => attachment.state === "added")
    .map((attachment) => (attachment.serverPath ?? "").trim())
    .filter((path) => path.length > 0);
}
