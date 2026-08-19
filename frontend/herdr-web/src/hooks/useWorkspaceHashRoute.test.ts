import { describe, expect, it } from "vitest";
import { parseHash } from "../lib/hashRoute";
import { repairArgsForRoute } from "./useWorkspaceHashRoute";

/**
 * Route guard tests (the pure half of useWorkspaceHashRoute — the hook's
 * effects share repairArgsForRoute, so these cover the data→repair and
 * hashchange paths). The selection→hash echo's pending-deep-link
 * preservation (null selection + null data + ids in the hash → no clobber)
 * lives in the effect and needs a DOM; it is guarded by the early return
 * in useWorkspaceHashRoute.ts and re-verified by the P12 browser pass.
 */

describe("repairArgsForRoute", () => {
  it("passes a full #ws=&pane= deep link through", () => {
    const args = repairArgsForRoute(parseHash("#ws=wB&pane=wB:p1"), null);
    expect(args).toEqual({ workspaceId: "wB", paneId: "wB:p1" });
  });

  it("resolves a pane-only deep link from the pane id prefix", () => {
    const args = repairArgsForRoute(parseHash("#pane=wB:p1"), null);
    expect(args).toEqual({ workspaceId: "wB", paneId: "wB:p1" });
  });

  it("keeps the pane id but drops the unresolvable prefix (no colon)", () => {
    const args = repairArgsForRoute(parseHash("#pane=p1"), null);
    expect(args).toEqual({ workspaceId: null, paneId: "p1" });
  });

  it("repairs a vanished selection when the URL carries no ids", () => {
    expect(repairArgsForRoute(parseHash("#deck=1"), null)).toEqual({
      workspaceId: null,
      paneId: null,
    });
  });

  it("does nothing when a selection already exists and the URL is idle", () => {
    expect(repairArgsForRoute(parseHash(""), "w1")).toBe("none");
    expect(repairArgsForRoute(parseHash("#deck=1"), "w1")).toBe("none");
  });

  it("lets an explicit #ws= win over a stale selection", () => {
    expect(repairArgsForRoute(parseHash("#ws=wG"), "w1")).toEqual({
      workspaceId: "wG",
      paneId: null,
    });
  });

  it("preserves unknown params untouched by the guard", () => {
    const route = parseHash("#deck=1&pane=wB:p1");
    expect(repairArgsForRoute(route, "w1")).toEqual({ workspaceId: "wB", paneId: "wB:p1" });
    expect(route.params).toEqual({ deck: "1" });
  });
});
