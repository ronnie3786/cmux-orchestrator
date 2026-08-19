/**
 * Terminal frame wire type + byte decoding — port of the `TerminalFrame`
 * Codable (herdr-harness-ios/.../Models/APIResponses.swift) and the
 * `Data(base64Encoded:)` / `String(data:encoding:.utf8)` guard in
 * `TerminalGrid.apply(_:)`.
 */

/**
 * Wire shape of a terminal frame. `seq` is the JSON field name in the SSE
 * payload (Swift `CodingKeys.sequence = "seq"`); the property is kept named
 * `seq` here to stay 1:1 with the wire + Swift call sites.
 *
 * `encoding` is decoded but IGNORED by the grid, exactly like the Swift
 * `apply(_:)` which only reads `bytes` regardless of `encoding`.
 */
export interface TerminalFrame {
  type: string;
  bytes: string; // base64
  encoding: string; // IGNORED by the grid
  full: boolean;
  height: number;
  seq: number;
  width: number;
}

/**
 * base64 → UTF-8 payload.
 *
 * Mirrors Swift's
 *   `Data(base64Encoded: frame.bytes)` followed by
 *   `String(data: data, encoding: .utf8)`:
 *  - invalid base64  → null (caller must treat as non-destructive no-op)
 *  - invalid UTF-8   → null (TextDecoder with `fatal: true`)
 */
export function decodeFrameBytes(frame: TerminalFrame): string | null {
  let binary: string;
  try {
    binary = atob(frame.bytes);
  } catch {
    return null;
  }
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

/**
 * Test/fixture helper mirroring the Swift test's `terminalFrame(_:)`:
 * base64-encodes a UTF-8 text payload into a frame.
 */
export function makeTerminalFrame(
  text: string,
  full: boolean,
  seq: number,
  width: number,
  height: number,
): TerminalFrame {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 1) {
    binary += String.fromCharCode(bytes[i]);
  }
  return {
    type: "terminal.frame",
    bytes: btoa(binary),
    encoding: "base64",
    full,
    height,
    seq,
    width,
  };
}
