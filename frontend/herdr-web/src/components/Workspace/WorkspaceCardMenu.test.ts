import { describe, expect, it } from "vitest";
import { workspaceMenuItemsFor } from "./WorkspaceCardMenu";

describe("workspaceMenuItemsFor", () => {
  it("live mode: Focus on Mac, New tab, Rename workspace, Close workspace — all enabled", () => {
    const items = workspaceMenuItemsFor({ demo: false });
    expect(items.map((item) => item.id)).toEqual(["focus", "newTab", "rename", "close"]);
    for (const item of items) {
      expect(item.enabled).toBe(true);
    }
  });

  it("demo mode: every mutating item disabled", () => {
    const items = workspaceMenuItemsFor({ demo: true });
    expect(items).toHaveLength(4);
    for (const item of items) {
      expect(item.enabled).toBe(false);
    }
  });

  it("labels are byte-exact per doc 01 §6", () => {
    const items = workspaceMenuItemsFor({ demo: false });
    const labelOf = (id: string) => items.find((item) => item.id === id)?.label;
    expect(labelOf("focus")).toBe("Focus on Mac");
    expect(labelOf("newTab")).toBe("New tab");
    expect(labelOf("rename")).toBe("Rename workspace");
    expect(labelOf("close")).toBe("Close workspace");
  });
});
