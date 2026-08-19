import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../api/client";
import type { AttachmentUploadArgs } from "./attachmentsStore";
import {
  ATTACHMENT_MAX_BYTES,
  attachmentSizeError,
  bytesToBase64,
  setAttachmentUploadFn,
  useAttachmentsStore,
} from "./attachmentsStore";

describe("bytesToBase64", () => {
  it("encodes small arrays including high-byte values", () => {
    expect(bytesToBase64(new Uint8Array([0x00]))).toBe("AA==");
    expect(bytesToBase64(new Uint8Array([0x68, 0x69]))).toBe("aGk=");
    expect(bytesToBase64(new Uint8Array([0xff, 0xfe, 0xfd]))).toBe("//79");
    expect(bytesToBase64(new Uint8Array([]))).toBe("");
  });

  it("chunks past the apply() call-stack limit", () => {
    const length = 0x8000 + 2; // crosses one 0x8000 chunk boundary
    const bytes = new Uint8Array(length);
    for (let i = 0; i < length; i++) bytes[i] = i % 256;
    const expected = btoa(String.fromCharCode(...bytes));
    expect(bytesToBase64(bytes)).toBe(expected);
  });
});

describe("attachmentSizeError", () => {
  it("rejects empty files", () => {
    expect(attachmentSizeError(0)).toBe("File is empty");
  });

  it("rejects files over the 20 MB cap and accepts at the cap", () => {
    expect(attachmentSizeError(ATTACHMENT_MAX_BYTES + 1)).toBe("File exceeds 20 MB limit");
    expect(attachmentSizeError(ATTACHMENT_MAX_BYTES)).toBeNull();
    expect(attachmentSizeError(1024)).toBeNull();
  });
});

describe("useAttachmentsStore", () => {
  let wsCounter = 0;
  let ws: string;
  let uploaded: AttachmentUploadArgs[] = [];

  function makeFile(size: number, name = "note.txt", type = "text/plain"): File {
    return new File([new Uint8Array(size)], name, { type });
  }

  beforeEach(() => {
    // Unique workspace per test — the store has no reset action.
    wsCounter += 1;
    ws = `w-test-${wsCounter}`;
    uploaded = [];
    setAttachmentUploadFn(async (args) => {
      uploaded.push(args);
      return { path: `/srv/attachments/${args.filename}` };
    });
  });

  afterEach(() => {
    setAttachmentUploadFn(null);
  });

  it("transitions uploading → attached with the server path", async () => {
    useAttachmentsStore.getState().uploadFile(ws, makeFile(3, "a.txt"));
    expect(useAttachmentsStore.getState().byWorkspace[ws]?.[0]?.state).toBe("uploading");

    await vi.waitFor(() => {
      const attachment = useAttachmentsStore.getState().byWorkspace[ws]?.[0];
      expect(attachment?.state).toBe("attached");
      expect(attachment?.serverPath).toBe("/srv/attachments/a.txt");
      expect(attachment?.error).toBeUndefined();
    });
    expect(uploaded[0]?.workspaceId).toBe(ws);
    expect(uploaded[0]?.filename).toBe("a.txt");
    expect(uploaded[0]?.contentType).toBe("text/plain");
  });

  it("transitions uploading → failed with the error envelope message", async () => {
    setAttachmentUploadFn(() => {
      throw new ApiError("cmux_upstream_error", "cmux could not complete the request", 502);
    });
    useAttachmentsStore.getState().uploadFile(ws, makeFile(3, "b.txt"));
    await vi.waitFor(() => {
      const attachment = useAttachmentsStore.getState().byWorkspace[ws]?.[0];
      expect(attachment?.state).toBe("failed");
      expect(attachment?.error).toBe("cmux could not complete the request");
    });
  });

  it("fails oversized files immediately without a network call", () => {
    useAttachmentsStore.getState().uploadFile(ws, makeFile(ATTACHMENT_MAX_BYTES + 1, "big.bin"));
    const attachment = useAttachmentsStore.getState().byWorkspace[ws]?.[0];
    expect(attachment?.state).toBe("failed");
    expect(attachment?.error).toBe("File exceeds 20 MB limit");
    expect(uploaded).toEqual([]);
  });

  it("drops a record on remove (late upload results are no-ops)", async () => {
    const holder: { release: (() => void) | null } = { release: null };
    setAttachmentUploadFn(
      () =>
        new Promise<{ path: string }>((resolve) => {
          holder.release = () => resolve({ path: "/late" });
        }),
    );
    useAttachmentsStore.getState().uploadFile(ws, makeFile(3, "c.txt"));
    await vi.waitFor(() => expect(holder.release).not.toBeNull());
    const id = useAttachmentsStore.getState().byWorkspace[ws]?.[0]?.id;
    expect(id).toBeDefined();
    useAttachmentsStore.getState().remove(ws, id);
    expect(useAttachmentsStore.getState().byWorkspace[ws]).toBeUndefined();

    holder.release?.();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(useAttachmentsStore.getState().byWorkspace[ws]).toBeUndefined();
  });
});
