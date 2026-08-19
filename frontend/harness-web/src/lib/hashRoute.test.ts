import { describe, expect, it } from "vitest";
import { parseSessionHash, serializeSessionHash } from "./hashRoute";

describe("hashRoute", () => {
  it("parses plain uuid session hashes", () => {
    expect(parseSessionHash("#/sessions/136C7993-8FCA-459D-9BD5-DDE38C16C9AB")).toBe(
      "136C7993-8FCA-459D-9BD5-DDE38C16C9AB",
    );
  });

  it("parses multi-pane row ids (uuid|surfaceId, percent-encoded)", () => {
    const rowID = "136C7993-8FCA-459D-9BD5-DDE38C16C9AB|surface:28";
    expect(parseSessionHash(serializeSessionHash(rowID))).toBe(rowID);
  });

  it("round-trips arbitrary ids", () => {
    for (const rowID of ["a", "uuid-1", "uuid-1|surface:0", "we ird|id|again"]) {
      expect(parseSessionHash(serializeSessionHash(rowID))).toBe(rowID);
    }
  });

  it("returns null for absent, wrong, empty, or malformed hashes", () => {
    expect(parseSessionHash("")).toBe(null);
    expect(parseSessionHash("#/")).toBe(null);
    expect(parseSessionHash("#/token=abc123")).toBe(null);
    expect(parseSessionHash("#/sessions/")).toBe(null);
    expect(parseSessionHash("#/sessions/%zz")).toBe(null);
  });

  it("serializes null to the empty hash", () => {
    expect(serializeSessionHash(null)).toBe("");
    expect(serializeSessionHash("")).toBe("");
  });
});
