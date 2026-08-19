import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  activeAttachmentsOf,
  ATTACHMENT_MAX_BYTES,
  attachmentSizeError,
  inFlightCount,
  setAttachmentUploadFn,
  uploadedPaths,
  useAttachmentsStore,
  type Attachment,
  type AttachmentUploadFn,
} from "./attachmentsStore";
import { useConnectionStore } from "./connectionStore";

const WORKSPACE = "ws-uuid-a";
const TARGET = { index: 3, uuid: "ws-uuid-a" };

function file(name: string, size = 120, type = "text/plain"): File {
  // A real File is needed for the picker/voice-note shapes; the size here is
  // what the chip and the upload guards see.
  return new File([new Uint8Array(Math.min(size, 4))], name, { type });
}

function store() {
  return useAttachmentsStore.getState();
}

function flush(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (error: unknown) => void;
} {
  let resolveFn!: (value: T) => void;
  let rejectFn!: (error: unknown) => void;
  const promise = new Promise<T>((resolve, reject) => {
    resolveFn = resolve;
    rejectFn = reject;
  });
  return { promise, resolve: resolveFn, reject: rejectFn };
}

interface UploadStub {
  fn: AttachmentUploadFn;
  /** Attachments handed to the stub, in call order. */
  calls: Attachment[];
  /** Resolve/reject the outcome of call N (1-based). */
  outcome: (call: number) => { resolve: (value: string) => void; reject: (error: unknown) => void };
}

function makeUploadStub(): UploadStub {
  const calls: Attachment[] = [];
  const outcomes = new Map<number, ReturnType<typeof deferred<string>>>();
  const fn: AttachmentUploadFn = (attachment) => {
    calls.push(attachment);
    const outcome = deferred<string>();
    outcomes.set(calls.length, outcome);
    return outcome.promise;
  };
  return {
    fn,
    calls,
    outcome: (call) => outcomes.get(call) as ReturnType<typeof deferred<string>>,
  };
}

beforeEach(() => {
  useAttachmentsStore.setState({ byWorkspace: {}, activeWorkspaceID: null });
  useConnectionStore.setState({ errorMessage: null });
  setAttachmentUploadFn(null);
});

describe("addFiles (iOS attachmentFilesPicked + uploadAttachmentEffect)", () => {
  it("creates one uploading record per file and uploads each to the workspace target", async () => {
    const stub = makeUploadStub();
    setAttachmentUploadFn(stub.fn);
    store().selectWorkspace(WORKSPACE);

    const photo = file("rx-photo.jpg", 1200, "image/jpeg");
    const log = file("build.log", 340, "text/plain");
    store().addFiles([photo, log], WORKSPACE, TARGET);

    const attachments = store().byWorkspace[WORKSPACE] ?? [];
    expect(attachments).toHaveLength(2);
    expect(attachments.map((a) => a.state)).toEqual(["uploading", "uploading"]);
    expect(attachments.map((a) => a.name)).toEqual(["rx-photo.jpg", "build.log"]);
    expect(attachments[0]?.mime).toBe("image/jpeg");
    expect(attachments[0]?.file).toBe(photo);
    expect(inFlightCount(attachments)).toBe(2);

    // Both uploads started against the captured target.
    expect(stub.calls).toHaveLength(2);
    for (const call of stub.calls) {
      expect(call.targetIndex).toBe(3);
      expect(call.targetUUID).toBe("ws-uuid-a");
    }

    stub.outcome(1).resolve("/tmp/cmux-harness-uploads/abc.jpg");
    stub.outcome(2).resolve("/tmp/cmux-harness-uploads/def.log");
    await flush();

    const done = store().byWorkspace[WORKSPACE] ?? [];
    expect(done.map((a) => a.state)).toEqual(["added", "added"]);
    expect(uploadedPaths(done)).toEqual([
      "/tmp/cmux-harness-uploads/abc.jpg",
      "/tmp/cmux-harness-uploads/def.log",
    ]);
  });

  it("appends to existing attachments instead of replacing them", () => {
    const stub = makeUploadStub();
    setAttachmentUploadFn(stub.fn);
    store().selectWorkspace(WORKSPACE);

    store().addFiles([file("one.txt")], WORKSPACE, TARGET);
    store().addFiles([file("two.txt")], WORKSPACE, TARGET);

    const attachments = store().byWorkspace[WORKSPACE] ?? [];
    expect(attachments.map((a) => a.name)).toEqual(["one.txt", "two.txt"]);
    stub.outcome(1).resolve("/tmp/1");
    stub.outcome(2).resolve("/tmp/2");
    void flush();
  });

  it("keeps workspaces isolated (iOS terminalAttachments[workspaceID])", async () => {
    const stub = makeUploadStub();
    setAttachmentUploadFn(stub.fn);
    store().selectWorkspace(WORKSPACE);

    store().addFiles([file("a.txt")], WORKSPACE, TARGET);
    store().addFiles([file("b.txt")], "ws-uuid-b", { index: 7, uuid: "ws-uuid-b" });

    expect(store().byWorkspace[WORKSPACE]?.map((a) => a.name)).toEqual(["a.txt"]);
    expect(store().byWorkspace["ws-uuid-b"]?.map((a) => a.name)).toEqual(["b.txt"]);
    expect(stub.calls[1]?.targetIndex).toBe(7);

    stub.outcome(1).resolve("/tmp/a");
    stub.outcome(2).resolve("/tmp/b");
    await flush();
    // Switching the selection switches which attachments the input row sees.
    store().selectWorkspace("ws-uuid-b");
    expect(activeAttachmentsOf(store()).map((a) => a.name)).toEqual(["b.txt"]);
  });
});

describe("upload outcomes", () => {
  it("marks the record error with the message on failure, other uploads unaffected", async () => {
    const stub = makeUploadStub();
    setAttachmentUploadFn(stub.fn);
    store().selectWorkspace(WORKSPACE);

    store().addFiles([file("bad.txt"), file("good.txt")], WORKSPACE, TARGET);
    stub.outcome(1).reject(new Error("Connection lost"));
    stub.outcome(2).resolve("/tmp/good");
    await flush();

    const [bad, good] = store().byWorkspace[WORKSPACE] ?? [];
    expect(bad?.state).toBe("error");
    expect(bad?.error).toBe("Connection lost");
    expect(good?.state).toBe("added");
    expect(good?.serverPath).toBe("/tmp/good");
    expect(inFlightCount(store().byWorkspace[WORKSPACE] ?? [])).toBe(0);
  });

  it("uses a generic message for non-Error rejections", async () => {
    const stub = makeUploadStub();
    setAttachmentUploadFn(stub.fn);
    store().selectWorkspace(WORKSPACE);

    store().addFiles([file("bad.txt")], WORKSPACE, TARGET);
    stub.outcome(1).reject("boom");
    await flush();

    const [bad] = store().byWorkspace[WORKSPACE] ?? [];
    expect(bad?.state).toBe("error");
    expect(bad?.error).toBe("Upload failed");
  });

  it("clears the global error banner on success (iOS errorMessage = nil)", async () => {
    const stub = makeUploadStub();
    setAttachmentUploadFn(stub.fn);
    useConnectionStore.setState({ errorMessage: "Send failed" });
    store().selectWorkspace(WORKSPACE);

    store().addFiles([file("ok.txt")], WORKSPACE, TARGET);
    stub.outcome(1).resolve("/tmp/ok");
    await flush();

    expect(useConnectionStore.getState().errorMessage).toBeNull();
  });
});

describe("retry (iOS retryAttachment)", () => {
  it("re-uploads from the error state and lands added; target comes from the original add", async () => {
    const stub = makeUploadStub();
    setAttachmentUploadFn(stub.fn);
    store().selectWorkspace(WORKSPACE);

    store().addFiles([file("flaky.txt")], WORKSPACE, TARGET);
    stub.outcome(1).reject(new Error("Connection lost"));
    await flush();
    expect(store().byWorkspace[WORKSPACE]?.[0]?.state).toBe("error");

    store().retry(stub.calls[0]?.id as string);
    expect(store().byWorkspace[WORKSPACE]?.[0]?.state).toBe("uploading");
    expect(store().byWorkspace[WORKSPACE]?.[0]?.error).toBeUndefined();
    expect(stub.calls).toHaveLength(2);
    expect(stub.calls[1]?.targetIndex).toBe(3);
    expect(stub.calls[1]?.targetUUID).toBe("ws-uuid-a");

    stub.outcome(2).resolve("/tmp/flaky");
    await flush();
    const [attachment] = store().byWorkspace[WORKSPACE] ?? [];
    expect(attachment?.state).toBe("added");
    expect(attachment?.serverPath).toBe("/tmp/flaky");
  });

  it("is a no-op for unknown ids", () => {
    const stub = makeUploadStub();
    setAttachmentUploadFn(stub.fn);
    store().selectWorkspace(WORKSPACE);
    expect(() => store().retry("missing")).not.toThrow();
    expect(stub.calls).toHaveLength(0);
  });
});

describe("remove (iOS removeAttachment)", () => {
  it("drops the record and a late in-flight success is a no-op", async () => {
    const stub = makeUploadStub();
    setAttachmentUploadFn(stub.fn);
    store().selectWorkspace(WORKSPACE);

    store().addFiles([file("doomed.txt")], WORKSPACE, TARGET);
    const id = store().byWorkspace[WORKSPACE]?.[0]?.id;
    store().remove(id as string);
    expect(store().byWorkspace[WORKSPACE]).toBeUndefined();

    // The upload lands after the removal — the record must not come back.
    stub.outcome(1).resolve("/tmp/should-not-reappear");
    await flush();
    expect(store().byWorkspace[WORKSPACE]).toBeUndefined();
  });

  it("removes only from the active workspace", async () => {
    const stub = makeUploadStub();
    setAttachmentUploadFn(stub.fn);
    store().selectWorkspace(WORKSPACE);
    store().addFiles([file("a.txt")], WORKSPACE, TARGET);
    store().addFiles([file("b.txt")], "ws-uuid-b", { index: 7, uuid: "ws-uuid-b" });
    const idA = store().byWorkspace[WORKSPACE]?.[0]?.id;
    const idB = store().byWorkspace["ws-uuid-b"]?.[0]?.id;

    store().remove(idB as string); // wrong workspace: no-op
    expect(store().byWorkspace["ws-uuid-b"]).toHaveLength(1);

    store().remove(idA as string);
    expect(store().byWorkspace[WORKSPACE]).toBeUndefined();

    stub.outcome(1).resolve("/tmp/a");
    stub.outcome(2).resolve("/tmp/b");
    await flush();
  });
});

describe("clearActive (iOS sendDetailDraft clearing)", () => {
  it("clears only the active workspace's attachments", async () => {
    const stub = makeUploadStub();
    setAttachmentUploadFn(stub.fn);
    store().selectWorkspace(WORKSPACE);
    store().addFiles([file("a.txt")], WORKSPACE, TARGET);
    store().addFiles([file("b.txt")], "ws-uuid-b", { index: 7, uuid: "ws-uuid-b" });
    stub.outcome(1).resolve("/tmp/a");
    stub.outcome(2).resolve("/tmp/b");
    await flush();

    store().clearActive();
    expect(store().byWorkspace[WORKSPACE]).toBeUndefined();
    expect(store().byWorkspace["ws-uuid-b"]).toHaveLength(1);
  });
});

describe("trim (iOS trimDrafts analog)", () => {
  it("drops attachments for disappeared workspaces, keeps the rest", async () => {
    const stub = makeUploadStub();
    setAttachmentUploadFn(stub.fn);
    store().selectWorkspace(WORKSPACE);
    store().addFiles([file("a.txt")], WORKSPACE, TARGET);
    store().addFiles([file("b.txt")], "ws-uuid-b", { index: 7, uuid: "ws-uuid-b" });
    stub.outcome(1).resolve("/tmp/a");
    stub.outcome(2).resolve("/tmp/b");
    await flush();

    store().trim([WORKSPACE]);
    expect(store().byWorkspace[WORKSPACE]).toHaveLength(1);
    expect(store().byWorkspace["ws-uuid-b"]).toBeUndefined();
  });

  it("is a no-op when nothing disappeared", () => {
    const before = useAttachmentsStore.getState();
    store().trim([]);
    expect(useAttachmentsStore.getState()).toBe(before);
  });
});

describe("attachmentSizeError (iOS client-side guards)", () => {
  it("rejects empty files and files over the 20 MB cap", () => {
    expect(attachmentSizeError(0)).toBe("File is empty");
    expect(attachmentSizeError(-1)).toBe("File is empty");
    expect(attachmentSizeError(ATTACHMENT_MAX_BYTES)).toBeNull();
    expect(attachmentSizeError(ATTACHMENT_MAX_BYTES + 1)).toBe("File exceeds 20 MB limit");
  });
});

describe("default upload transport (POST /api/attachments)", () => {
  const successJson = {
    ok: true,
    attachment: {
      name: "ok.txt",
      size: 4,
      type: "text/plain",
      path: "/tmp/cmux-harness-uploads/ok.txt",
    },
  };

  it("uploads the raw file body and stores the server path", async () => {
    const fetchMock = vi.fn(async (..._args: unknown[]) => Response.json(successJson));
    vi.stubGlobal("fetch", fetchMock as unknown as typeof fetch);
    try {
      store().selectWorkspace(WORKSPACE);
      store().addFiles([file("ok.txt", 4, "text/plain")], WORKSPACE, TARGET);
      await flush();
      const [attachment] = store().byWorkspace[WORKSPACE] ?? [];
      expect(attachment?.state).toBe("added");
      expect(attachment?.serverPath).toBe("/tmp/cmux-harness-uploads/ok.txt");

      const [url, init] = (fetchMock.mock.calls[0] ?? []) as [string, RequestInit];
      expect(String(url)).toContain("/api/attachments");
      expect(init?.method).toBe("POST");
      expect((init?.body as Blob).size).toBe(4);
      const headers = new Headers(init?.headers as Record<string, string>);
      expect(headers.get("x-cmux-workspace-index")).toBe("3");
      expect(headers.get("x-cmux-workspace-uuid")).toBe("ws-uuid-a");
      expect(headers.get("content-type")).toBe("text/plain");
      expect(decodeURIComponent(headers.get("x-cmux-filename") ?? "")).toBe("ok.txt");
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("fails the chip before any network call when the file is over the cap", async () => {
    const fetchMock = vi.fn() as unknown as typeof fetch;
    vi.stubGlobal("fetch", fetchMock);
    try {
      // File size as the store sees it (guard reads size, not the bytes).
      const huge = file("huge.bin");
      Object.defineProperty(huge, "size", { value: ATTACHMENT_MAX_BYTES + 1 });
      store().selectWorkspace(WORKSPACE);
      store().addFiles([huge], WORKSPACE, TARGET);
      await flush();
      const [attachment] = store().byWorkspace[WORKSPACE] ?? [];
      expect(attachment?.state).toBe("error");
      expect(attachment?.error).toBe("File exceeds 20 MB limit");
      expect(fetchMock).not.toHaveBeenCalled();
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("surfaces server rejections as the chip error", async () => {
    const fetchMock = vi.fn(async () =>
      Response.json({ ok: false, error: "filename required" }, { status: 400 }),
    ) as unknown as typeof fetch;
    vi.stubGlobal("fetch", fetchMock);
    try {
      store().selectWorkspace(WORKSPACE);
      store().addFiles([file("bad.txt")], WORKSPACE, TARGET);
      await flush();
      const [attachment] = store().byWorkspace[WORKSPACE] ?? [];
      expect(attachment?.state).toBe("error");
      // The server's message surfaces (ApiError from requestJson), not a generic one.
      expect(attachment?.error).toBe("filename required");
    } finally {
      vi.unstubAllGlobals();
    }
  });
});

describe("activeAttachmentsOf / inFlightCount / uploadedPaths", () => {
  it("returns [] before a selection and counts only uploading records", () => {
    expect(activeAttachmentsOf({ byWorkspace: {}, activeWorkspaceID: null })).toEqual([]);
    expect(
      activeAttachmentsOf({
        byWorkspace: { a: [] },
        activeWorkspaceID: "a",
      }),
    ).toEqual([]);
    const attachments: Attachment[] = [
      { id: "1", name: "a", size: 1, mime: "", state: "uploading", file: new Blob(), targetIndex: 0, targetUUID: "" },
      { id: "2", name: "b", size: 1, mime: "", state: "added", serverPath: "/x", file: new Blob(), targetIndex: 0, targetUUID: "" },
      { id: "3", name: "c", size: 1, mime: "", state: "error", error: "x", file: new Blob(), targetIndex: 0, targetUUID: "" },
    ];
    expect(inFlightCount(attachments)).toBe(1);
    expect(uploadedPaths(attachments)).toEqual(["/x"]);
  });
});
