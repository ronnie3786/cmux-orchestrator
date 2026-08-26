import { getSingularPatch, type FileDiffMetadata } from "@pierre/diffs";

export type DiffFallbackReason = "metadata-only" | "parse-unavailable";

export interface ParsedDiffPresentation {
  fileDiff: FileDiffMetadata | null;
  fallbackReason: DiffFallbackReason | null;
}

/**
 * Converts a one-file Git patch into Pierre's render model.
 *
 * Pierre intentionally accepts Git metadata-only patches, such as pure
 * renames, mode changes, and binary changes. Those models contain no hunks,
 * so a renderer with its built-in file header disabled would otherwise show
 * a blank canvas. Keep those patches in the explicit raw-patch path instead.
 */
export function parseDiffPresentation(file: string, patch: string): ParsedDiffPresentation {
  if (patch === "") return { fileDiff: null, fallbackReason: null };
  try {
    const fileDiff = getSingularPatch(patch);
    if (fileDiff.hunks.length === 0) {
      return {
        fileDiff: null,
        fallbackReason: /^@@/m.test(patch) ? "parse-unavailable" : "metadata-only",
      };
    }

    // Pierre 1.3.2 otherwise caches same-path patches under the filename. A
    // content-derived key prevents a refreshed diff from displaying stale code.
    fileDiff.cacheKey = `${file}#${hashPatch(patch)}`;
    return { fileDiff, fallbackReason: null };
  } catch {
    return { fileDiff: null, fallbackReason: "parse-unavailable" };
  }
}

function hashPatch(value: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}
