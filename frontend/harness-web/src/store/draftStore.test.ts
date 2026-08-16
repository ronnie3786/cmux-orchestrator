import { afterEach, describe, expect, it, vi } from "vitest";

/**
 * localStorage-backed draft plumbing (iOS `detailDrafts` parity). Each test
 * gets a fresh module instance so the lazy hydration flag and store state
 * don't leak between cases.
 */

function createMemoryStorage(): Storage {
  let map = new Map<string, string>();
  return {
    get length() {
      return map.size;
    },
    clear: () => {
      map = new Map();
    },
    getItem: (key: string) => (map.has(key) ? map.get(key)! : null),
    key: (index: number) => Array.from(map.keys())[index] ?? null,
    removeItem: (key: string) => {
      map.delete(key);
    },
    setItem: (key: string, value: string) => {
      map.set(key, String(value));
    },
  };
}

async function setup(seed: Record<string, string> = {}) {
  const storage = createMemoryStorage();
  for (const [key, value] of Object.entries(seed)) {
    storage.setItem(key, value);
  }
  vi.stubGlobal("localStorage", storage);
  vi.resetModules();
  const mod = await import("./draftStore");
  return { store: mod.useDraftStore, storage };
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.resetModules();
});

describe("draftStore", () => {
  it("restores a workspace's persisted draft on selection (iOS loadDetailDraft)", async () => {
    const { store, storage } = await setup({ "harness-web:draft:abc": "hello draft" });
    store.getState().selectDraft("abc");
    expect(store.getState().activeDraft).toBe("hello draft");

    // A workspace without a persisted draft starts empty (iOS `?? ""`).
    store.getState().selectDraft("other");
    expect(store.getState().activeDraft).toBe("");
    expect(storage.getItem("harness-web:draft:other")).toBeNull();
  });

  it("persists edits and removes the entry when cleared (iOS persistDetailDraft)", async () => {
    const { store, storage } = await setup();
    store.getState().selectDraft("abc");
    store.getState().setDraft("typed text");
    expect(storage.getItem("harness-web:draft:abc")).toBe("typed text");
    expect(store.getState().drafts).toEqual({ abc: "typed text" });

    store.getState().clearDraft();
    expect(store.getState().activeDraft).toBe("");
    expect(storage.getItem("harness-web:draft:abc")).toBeNull();
    expect(store.getState().drafts).toEqual({});
  });

  it("appends formatted blocks with iOS appendPromptBlock semantics", async () => {
    const { store } = await setup({ "harness-web:draft:abc": "Existing note." });
    store.getState().selectDraft("abc");

    store.getState().appendBlock("  Please address this review comment:\n\nFile: a.swift\n");
    expect(store.getState().activeDraft).toBe(
      "Existing note.\n\nPlease address this review comment:\n\nFile: a.swift",
    );

    // An empty draft receives just the trimmed block.
    store.getState().clearDraft();
    store.getState().appendBlock("  block only  ");
    expect(store.getState().activeDraft).toBe("block only");
  });

  it("appends tokens with iOS appendPromptToken semantics (file/skill inserts)", async () => {
    const { store, storage } = await setup({ "harness-web:draft:abc": "Open" });
    store.getState().selectDraft("abc");

    // iOS fileSearchAppendsBacktickedProjectRelativePath: "Open" + token.
    store.getState().appendToken("`Sources/AppView.swift`");
    expect(store.getState().activeDraft).toBe("Open `Sources/AppView.swift`");
    expect(storage.getItem("harness-web:draft:abc")).toBe("Open `Sources/AppView.swift`");

    // Trailing whitespace: no extra space inserted (Swift isWhitespace check).
    store.getState().appendToken("/ios-review");
    expect(store.getState().activeDraft).toBe("Open `Sources/AppView.swift` /ios-review");

    // An empty draft receives just the token (Swift guard !draft.isEmpty).
    store.getState().clearDraft();
    store.getState().appendToken("$ios-review");
    expect(store.getState().activeDraft).toBe("$ios-review");
  });

  it("trims drafts for workspaces that no longer exist (iOS trimDrafts)", async () => {
    const { store, storage } = await setup({
      "harness-web:draft:keep": "a",
      "harness-web:draft:gone": "b",
    });
    store.getState().selectDraft("keep");
    expect(store.getState().drafts).toEqual({ keep: "a", gone: "b" });

    store.getState().trimDrafts(["keep"]);
    expect(store.getState().drafts).toEqual({ keep: "a" });
    expect(storage.getItem("harness-web:draft:gone")).toBeNull();
    expect(storage.getItem("harness-web:draft:keep")).toBe("a");
  });

  it("focus requests bump monotonically and only the current one clears (iOS detailInputFocusRequest)", async () => {
    const { store } = await setup();
    store.getState().selectDraft("abc");

    store.getState().requestFocus();
    expect(store.getState().focusRequest).toBe(1);
    store.getState().requestFocus();
    expect(store.getState().focusRequest).toBe(2);

    // A stale handle must not clear a newer request.
    store.getState().markFocusHandled(1);
    expect(store.getState().focusRequest).toBe(2);
    store.getState().markFocusHandled(2);
    expect(store.getState().focusRequest).toBe(0);
  });

  it("ignores appendBlock before any draft is selected", async () => {
    const { store } = await setup();
    store.getState().appendBlock("block");
    expect(store.getState().activeDraft).toBe("");
  });
});
