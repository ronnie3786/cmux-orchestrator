/**
 * Per-workspace composer attachments (P9-run-B). Port of the Phase-1
 * attachmentsStore, re-pointed at the herdr harness endpoint
 * POST /api/v1/workspaces/{id}/attachments (base64 JSON, doc 02 §2).
 *
 * State per attachment (doc 01 §6 vocabulary):
 *   uploading --success--> attached (serverPath set, error cleared)
 *   uploading --failure--> failed (message set; oversized files fail before
 *                            any network call)
 *   any --remove()--------> record dropped (a late upload result is a no-op,
 *                           like the Phase-1 firstIndex-guarded reducers)
 */

import { create } from "zustand";
import { uploadWorkspaceAttachment } from "../api/tools";
export { bytesToBase64 } from "../api/tools";

/** AttachmentPolicy cap (doc 01 §4.3): 20 MB per file. */
export const ATTACHMENT_MAX_BYTES = 20 * 1024 * 1024;

export type AttachmentState = "uploading" | "attached" | "failed";

export interface Attachment {
  id: string;
  filename: string;
  size: number;
  /** File.type ("" when unknown). */
  mime: string;
  state: AttachmentState;
  /** Server-stored absolute path (attachment.path) once attached. */
  serverPath?: string;
  /** Failure message for the failed state. */
  error?: string;
  /** In-memory source from the file picker. */
  file: Blob;
}

/** Client-side guard (mirrors the Phase-1 attachmentSizeError). */
export function attachmentSizeError(size: number): string | null {
  if (size <= 0) return "File is empty";
  if (size > ATTACHMENT_MAX_BYTES) return "File exceeds 20 MB limit";
  return null;
}

export interface AttachmentUploadArgs {
  workspaceId: string;
  filename: string;
  contentType?: string;
  data: Uint8Array;
}

/** Resolves to the server-stored path. */
export type AttachmentUploadFn = (args: AttachmentUploadArgs) => Promise<{ path: string }>;

const defaultUploadFn: AttachmentUploadFn = async (args) => {
  const response = await uploadWorkspaceAttachment(args.workspaceId, {
    filename: args.filename,
    contentType: args.contentType,
    data: args.data,
  });
  const path = (response.attachment?.path ?? "").trim();
  if (path.length === 0) throw new Error("Attachment upload failed");
  return { path };
};

/** Test seam: stub the transport (null restores the real endpoint). */
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
  /** All attachments, keyed by workspace id. */
  byWorkspace: Record<string, Attachment[]>;
  /**
   * Append one `uploading` record and start its upload (size-capped files
   * land immediately in `failed` with the size message — no network call).
   */
  uploadFile: (workspaceId: string, file: File) => void;
  remove: (workspaceId: string, id: string) => void;
}

type SetState = (
  partial:
    | Partial<AttachmentsStoreState>
    | ((state: AttachmentsStoreState) => Partial<AttachmentsStoreState>),
) => void;
type GetState = () => AttachmentsStoreState;

/** No-op when the record is gone (removed while an upload was in flight). */
function patchAttachment(
  set: SetState,
  workspaceId: string,
  id: string,
  patch: Partial<Attachment>,
): void {
  set((state) => {
    const list = state.byWorkspace[workspaceId];
    if (!list) return {};
    const index = list.findIndex((attachment) => attachment.id === id);
    if (index === -1) return {};
    const next = [...list];
    next[index] = { ...next[index], ...patch };
    return { byWorkspace: { ...state.byWorkspace, [workspaceId]: next } };
  });
}

function runUpload(set: SetState, get: GetState, workspaceId: string, id: string): void {
  void (async () => {
    const attachment = (get().byWorkspace[workspaceId] ?? []).find(
      (candidate) => candidate.id === id,
    );
    if (!attachment) return;
    let bytes: Uint8Array;
    try {
      bytes = new Uint8Array(await attachment.file.arrayBuffer());
    } catch {
      patchAttachment(set, workspaceId, id, { state: "failed", error: "Read failed" });
      return;
    }
    try {
      const { path } = await uploadFn({
        workspaceId,
        filename: attachment.filename,
        contentType: attachment.mime === "" ? undefined : attachment.mime,
        data: bytes,
      });
      patchAttachment(set, workspaceId, id, { state: "attached", serverPath: path, error: undefined });
    } catch (error) {
      const message =
        error instanceof Error && error.message.length > 0 ? error.message : "Upload failed";
      patchAttachment(set, workspaceId, id, { state: "failed", error: message });
    }
  })();
}

export const useAttachmentsStore = create<AttachmentsStoreState>()((set, get) => ({
  byWorkspace: {},

  uploadFile: (workspaceId, file) => {
    const id = makeAttachmentID();
    const sizeError = attachmentSizeError(file.size);
    set((state) => ({
      byWorkspace: {
        ...state.byWorkspace,
        [workspaceId]: [
          ...(state.byWorkspace[workspaceId] ?? []),
          {
            id,
            filename: file.name === "" ? "attachment" : file.name,
            size: file.size,
            mime: file.type,
            state: sizeError === null ? "uploading" : "failed",
            error: sizeError ?? undefined,
            file,
          },
        ],
      },
    }));
    if (sizeError !== null) return;
    runUpload(set, get, workspaceId, id);
  },

  remove: (workspaceId, id) => {
    set((state) => {
      const list = state.byWorkspace[workspaceId];
      if (!list) return {};
      const next = list.filter((attachment) => attachment.id !== id);
      if (next.length === list.length) return {};
      const byWorkspace = { ...state.byWorkspace };
      if (next.length === 0) delete byWorkspace[workspaceId];
      else byWorkspace[workspaceId] = next;
      return { byWorkspace };
    });
  },
}));
