/**
 * Deterministic TS port of
 * `herdr-harness-ios/Infrastructure/PiConversationSSEParser.swift`.
 *
 * Line rules (mirrored exactly):
 *  - `:` comment lines (heartbeats) count as `.activity`.
 *  - `event:` / `id:` lines update record state, never dispatch.
 *  - `data:` lines accumulate; a complete envelope dispatches as soon as the
 *    joined payload decodes (URLSession's line sequence can omit the blank
 *    separator), while an undecodable payload stays buffered to preserve
 *    multiline SSE. The blank line force-dispatches.
 *  - `ready` / `pi.ready` / `heartbeat` / `pi.heartbeat` → `.activity`
 *    (namespaced or not — the normalization rule).
 *  - `pi.error` / `pi.stream.closed` → throws `PiStreamEndedError`.
 *  - any other event name that is neither `pi.`-prefixed nor the default
 *    `message` is dropped entirely.
 *  - the SSE `id:` line is the cursor fallback
 *    (`PiConversationEnvelope.withCursor(_:)`).
 */

import {
  decodePiConversationEnvelope,
  piEnvelopeWithCursor,
} from "./types";
import type { PiConversationStreamEvent } from "./types";

/** Swift `APIError.streamEnded` (SSE `pi.error` / `pi.stream.closed`). */
export class PiStreamEndedError extends Error {
  constructor() {
    super("Pi stream ended");
    this.name = "PiStreamEndedError";
  }
}

/** Swift `APIError.invalidResponse` (undecodable payload at forced dispatch). */
export class PiInvalidResponseError extends Error {
  constructor() {
    super("Invalid Pi SSE response payload");
    this.name = "PiInvalidResponseError";
  }
}

function fieldValue(line: string, prefixLength: number): string {
  let value = line.slice(prefixLength);
  if (value.startsWith(" ")) value = value.slice(1);
  return value;
}

export class PiConversationSSEParser {
  private eventName = "message";
  private eventID: string | null = null;
  private dataLines: string[] = [];

  /**
   * Feed one SSE line. Returns the dispatched event (or null), and throws
   * `PiStreamEndedError` / `PiInvalidResponseError` where the Swift parser
   * throws `APIError.streamEnded` / `APIError.invalidResponse`.
   */
  consume(line: string): PiConversationStreamEvent | null {
    if (line.startsWith(":")) {
      return { kind: "activity" };
    }
    if (line.startsWith("event:")) {
      this.eventName = fieldValue(line, 6);
      return null;
    }
    if (line.startsWith("id:")) {
      this.eventID = fieldValue(line, 3);
      return null;
    }
    if (line.startsWith("data:")) {
      this.dataLines.push(fieldValue(line, 5));
      return this.dispatchIfComplete(false);
    }
    if (line !== "") {
      return null;
    }
    return this.dispatchIfComplete(true);
  }

  /**
   * URLSession's async line sequence can omit the empty separator between
   * SSE records on a long-lived response. Pi payloads are JSON, so dispatch
   * as soon as the accumulated data forms a complete envelope. Keeping an
   * incomplete payload buffered preserves standard multiline SSE support.
   */
  private dispatchIfComplete(force: boolean): PiConversationStreamEvent | null {
    if (this.dataLines.length === 0) {
      if (force) this.resetRecord();
      return null;
    }

    const dispatchedEventName = this.eventName;
    const dispatchedID = this.eventID;
    const payload = this.dataLines.join("\n");

    switch (dispatchedEventName) {
      case "ready":
      case "pi.ready":
      case "heartbeat":
      case "pi.heartbeat":
        this.resetRecord();
        return { kind: "activity" };
      case "pi.error":
      case "pi.stream.closed":
        this.resetRecord();
        throw new PiStreamEndedError();
      default: {
        if (!dispatchedEventName.startsWith("pi.") && dispatchedEventName !== "message") {
          if (force) this.resetRecord();
          return null;
        }
        if (payload === "") {
          if (force) this.resetRecord();
          return null;
        }
        try {
          const envelope = decodePiConversationEnvelope(payload);
          this.resetRecord();
          return { kind: "envelope", envelope: piEnvelopeWithCursor(envelope, dispatchedID) };
        } catch {
          if (!force) return null;
          this.resetRecord();
          throw new PiInvalidResponseError();
        }
      }
    }
  }

  private resetRecord(): void {
    this.eventName = "message";
    this.eventID = null;
    this.dataLines = [];
  }
}
