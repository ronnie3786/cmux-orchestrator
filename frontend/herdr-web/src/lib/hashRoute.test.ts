import { describe, expect, it } from "vitest";
import { parseHash, serializeHash, workspaceFromPaneId } from "./hashRoute";

const EMPTY = { workspaceId: null, paneId: null, params: {} };

describe("parseHash", () => {
  it("returns an empty route for no hash", () => {
    expect(parseHash("")).toEqual(EMPTY);
  });

  it("parses a bare '#' as empty", () => {
    expect(parseHash("#")).toEqual(EMPTY);
  });

  it("parses ws only", () => {
    expect(parseHash("#ws=wG")).toEqual({ workspaceId: "wG", paneId: null, params: {} });
  });

  it("parses pane only (deep link without a workspace)", () => {
    expect(parseHash("#pane=wG:p1")).toEqual({ workspaceId: null, paneId: "wG:p1", params: {} });
  });

  it("parses both ws and pane", () => {
    expect(parseHash("#ws=wG&pane=wG:p1")).toEqual({
      workspaceId: "wG",
      paneId: "wG:p1",
      params: {},
    });
  });

  it("decodes percent-encoded ids (colons survive)", () => {
    const route = parseHash("#ws=a%3Ab&pane=wG:p1");
    expect(route.workspaceId).toBe("a:b");
    expect(route.paneId).toBe("wG:p1");
  });

  it("preserves unknown params and their order", () => {
    const route = parseHash("#deck=1&ws=w1&theme=dark");
    expect(route.workspaceId).toBe("w1");
    expect(route.paneId).toBe(null);
    expect(Object.keys(route.params)).toEqual(["deck", "theme"]);
    expect(route.params).toEqual({ deck: "1", theme: "dark" });
  });

  it("treats an empty known value as null", () => {
    expect(parseHash("#ws=&pane=")).toEqual(EMPTY);
  });

  it("keeps params without '=' as empty strings", () => {
    expect(parseHash("#ws=only")).toEqual({ workspaceId: "only", paneId: null, params: {} });
    expect(parseHash("#deck").params).toEqual({ deck: "" });
  });

  it("drops malformed percent-encoding keys; bad values read as empty", () => {
    expect(parseHash("#ws=%E0&pane=w1:p1")).toEqual({ workspaceId: null, paneId: "w1:p1", params: {} });
    expect(parseHash("#bad=%E0%41%88")).toEqual({ workspaceId: null, paneId: null, params: { bad: "" } });
  });

  it("first occurrence wins for duplicate unknown keys", () => {
    expect(parseHash("#deck=1&deck=2").params).toEqual({ deck: "1" });
  });

  it("ignores empty segments", () => {
    expect(parseHash("#ws=w1&&")).toEqual({ workspaceId: "w1", paneId: null, params: {} });
  });
});

describe("workspaceFromPaneId", () => {
  it("resolves the workspace prefix of a pane id", () => {
    expect(workspaceFromPaneId("wB:p1")).toBe("wB");
    expect(workspaceFromPaneId("w1:p1")).toBe("w1");
  });

  it("keeps the first segment when the id has more colons", () => {
    expect(workspaceFromPaneId("a:b:c")).toBe("a");
  });

  it("returns null for ids without a colon", () => {
    expect(workspaceFromPaneId("p1")).toBe(null);
    expect(workspaceFromPaneId("")).toBe(null);
  });

  it("returns null for a leading colon (empty workspace id)", () => {
    expect(workspaceFromPaneId(":p1")).toBe(null);
  });
});

describe("serializeHash", () => {
  it("serializes an empty route to ''", () => {
    expect(serializeHash(EMPTY)).toBe("");
  });

  it("serializes ws and pane", () => {
    expect(serializeHash({ workspaceId: "wG", paneId: "wG:p1", params: {} })).toBe("#ws=wG&pane=wG%3Ap1");
  });

  it("omits null known keys", () => {
    expect(serializeHash({ workspaceId: "wG", paneId: null, params: {} })).toBe("#ws=wG");
  });

  it("emits unknown params after the known keys, in order", () => {
    const out = serializeHash({ workspaceId: "w1", paneId: null, params: { deck: "1", theme: "dark" } });
    expect(out).toBe("#ws=w1&deck=1&theme=dark");
  });

  it("round-trips", () => {
    const route = { workspaceId: "wG", paneId: "wG:p1", params: { deck: "1" } };
    expect(parseHash(serializeHash(route))).toEqual(route);
  });
});
