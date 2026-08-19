/**
 * Terminal SSE line parser — faithful port of `TerminalSSEParser`
 * (herdr-harness-ios/.../Infrastructure/HerdrAPIClient.swift, line ~509).
 *
 * Created beyond the P4 file list because the approved plan requires
 * `terminalSSEActivityParsing` to be ported 1:1 and that test drives this
 * class, not `TerminalGrid`.
 */

import type { TerminalFrame } from "./frame";

export type TerminalStreamEvent =
  | { kind: "ready" }
  | { kind: "activity" }
  | { kind: "frame"; frame: TerminalFrame };

/**
 * Port of `APIError`'s terminal-stream cases. Swift throws
 * `APIError.streamEnded` / `APIError.invalidResponse`; the web port throws
 * `TerminalStreamError` with the corresponding code.
 */
export class TerminalStreamError extends Error {
  constructor(
    public readonly code: "streamEnded" | "invalidResponse",
  ) {
    super(code);
    this.name = "TerminalStreamError";
  }
}

/**
 * Strict-ish JSON decode of a `TerminalFrame` payload, mirroring Swift
 * `JSONDecoder().decode(TerminalFrame.self, from:)`: all seven fields must be
 * present with the right JSON type (`seq` is the wire key for `sequence`);
 * extra fields are ignored (Swift default), a wrong type or missing field is
 * a decode failure (null).
 */
function decodeTerminalFrame(json: string): TerminalFrame | null {
  let value: unknown;
  try {
    value = JSON.parse(json);
  } catch {
    return null;
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return null;
  }
  const obj = value as Record<string, unknown>;
  if (
    typeof obj.type !== "string" ||
    typeof obj.bytes !== "string" ||
    typeof obj.encoding !== "string" ||
    typeof obj.full !== "boolean" ||
    typeof obj.height !== "number" ||
    typeof obj.seq !== "number" ||
    typeof obj.width !== "number"
  ) {
    return null;
  }
  return {
    type: obj.type,
    bytes: obj.bytes,
    encoding: obj.encoding,
    full: obj.full,
    height: obj.height,
    seq: obj.seq,
    width: obj.width,
  };
}

export class TerminalSSEParser {
  private eventName = "message";
  private dataLines: string[] = [];

  /**
   * Port of `consume(line:)`. Returns the dispatched event, or null.
   * Throws `TerminalStreamError` exactly where the Swift version throws
   * (stream-ended events; undecodable frame on a forced dispatch).
   */
  consume(line: string): TerminalStreamEvent | null {
    if (line.startsWith(":")) {
      return { kind: "activity" };
    }
    if (line.startsWith("event:")) {
      this.eventName = line.slice(6).trim();
      return null;
    }
    if (line.startsWith("data:")) {
      this.dataLines.push(line.slice(5).trim());
      return this.dispatchIfComplete(false);
    }
    if (line !== "") return null;
    return this.dispatchIfComplete(true);
  }

  private dispatchIfComplete(force: boolean): TerminalStreamEvent | null {
    if (this.dataLines.length === 0) {
      if (force) this.resetRecord();
      return null;
    }

    switch (this.eventName) {
      case "ready":
        this.resetRecord();
        return { kind: "ready" };
      case "heartbeat":
        this.resetRecord();
        return { kind: "activity" };
      case "terminal.frame": {
        const payload = this.dataLines.join("\n");
        const frame = decodeTerminalFrame(payload);
        if (frame === null) {
          if (force) {
            this.resetRecord();
            throw new TerminalStreamError("invalidResponse");
          }
          return null;
        }
        this.resetRecord();
        return { kind: "frame", frame };
      }
      case "terminal.error":
      case "terminal.closed":
        this.resetRecord();
        throw new TerminalStreamError("streamEnded");
      default:
        if (force) this.resetRecord();
        return null;
    }
  }

  private resetRecord(): void {
    this.eventName = "message";
    this.dataLines = [];
  }
}
