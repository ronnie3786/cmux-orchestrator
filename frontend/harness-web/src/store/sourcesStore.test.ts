import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useSourcesStore } from "./sourcesStore";

const SOURCES_KEY = "harness-web:sources";

function installLocalStorage(initial: Record<string, string> = {}) {
  const store = new Map<string, string>(Object.entries(initial));
  (globalThis as { localStorage?: unknown }).localStorage = {
    getItem: (key: string) => (store.has(key) ? store.get(key) : null),
    setItem: (key: string, value: string) => {
      store.set(key, String(value));
    },
    removeItem: (key: string) => {
      store.delete(key);
    },
    clear: () => store.clear(),
  };
  return store;
}

function reinit() {
  // The store reads localStorage at module import (which happens before the
  // test's localStorage mock exists), so seed a clean state per test.
  useSourcesStore.setState({ sources: [], activeId: null });
}

describe("sourcesStore", () => {
  beforeEach(() => {
    installLocalStorage();
    reinit();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("requires a server URL (iOS error string)", () => {
    const error = useSourcesStore.getState().addSource("QA", "   ");
    expect(error).toBe("Server URL is required.");
    expect(useSourcesStore.getState().sources).toEqual([]);
  });

  it("adds a source, persists it under harness-web:sources, and makes it active", () => {
    const storage = installLocalStorage();
    const error = useSourcesStore.getState().addSource("My Mac", "http://192.168.1.50:9091");
    expect(error).toBeNull();

    const state = useSourcesStore.getState();
    expect(state.sources).toHaveLength(1);
    expect(state.sources[0]).toMatchObject({ name: "My Mac", url: "http://192.168.1.50:9091" });
    expect(state.activeId).toBe(state.sources[0].id);

    const persisted = JSON.parse(storage.get(SOURCES_KEY) ?? "[]") as Array<Record<string, unknown>>;
    expect(persisted).toHaveLength(1);
    expect(persisted[0]).toMatchObject({ name: "My Mac", url: "http://192.168.1.50:9091" });
    expect(typeof persisted[0]?.id).toBe("string");
  });

  it("falls back to the first remaining source when the active one is deleted (iOS parity)", () => {
    useSourcesStore.getState().addSource("A", "http://a:9091");
    useSourcesStore.getState().addSource("B", "http://b:9091");
    const active = useSourcesStore.getState().activeId;

    useSourcesStore.getState().deleteSource(active as string);
    const state = useSourcesStore.getState();
    expect(state.sources.map((s) => s.name)).toEqual(["A"]);
    expect(state.activeId).toBe(state.sources[0].id);

    useSourcesStore.getState().deleteSource(state.sources[0].id);
    expect(useSourcesStore.getState().sources).toEqual([]);
    expect(useSourcesStore.getState().activeId).toBeNull();
  });

  it("ignores selecting an unknown source", () => {
    useSourcesStore.getState().addSource("A", "http://a:9091");
    const before = useSourcesStore.getState().activeId;
    useSourcesStore.getState().selectSource("nope");
    expect(useSourcesStore.getState().activeId).toBe(before);
  });

  it("selects a saved source", () => {
    useSourcesStore.getState().addSource("A", "http://a:9091");
    useSourcesStore.getState().addSource("B", "http://b:9091");
    const b = useSourcesStore.getState().sources.find((s) => s.name === "B");
    useSourcesStore.getState().selectSource(b?.id ?? "");
    expect(useSourcesStore.getState().activeId).toBe(b?.id);
  });
});
