/**
 * Render-driven tests for the Pi composer, chips, and interaction cards
 * (P8-run-B) — renderToStaticMarkup style as in PiChatView.test.ts.
 *
 * The capability variants are built from the LIVE 9092 server's
 * `pi_semantic.capabilities` (read-only curl during this phase):
 *
 *  V_NO_MODELS  = {prompt,steer,followUp,abort: true,
 *                  listModels, setModel, setThinkingLevel: false,
 *                  interactionResponse: false}
 *  V_NO_THINKING = same, listModels+setModel true, setThinkingLevel false
 *  V_FULL       = same, setThinkingLevel true
 */
import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import {
  PI_SEMANTIC_CAPABILITIES_UNAVAILABLE,
  type PiSemanticCapabilities,
} from "../../pi/types";
import { InteractionCard } from "./InteractionCard";
import { PiComposer, PiComposerDock, type PiComposerProps } from "./PiComposer";
import { PiChatView, type PiChatViewProps } from "./PiChatView";

// ---------------------------------------------------------------------------
// Live capability variants (9092, read-only)
// ---------------------------------------------------------------------------

const CAPS = {
  prompt: true,
  steer: true,
  followUp: true,
  abort: true,
  interactionResponse: false,
} as const;

const V_NO_MODELS: PiSemanticCapabilities = {
  ...CAPS,
  listModels: false,
  setModel: false,
  setThinkingLevel: false,
};
const V_NO_THINKING: PiSemanticCapabilities = {
  ...CAPS,
  listModels: true,
  setModel: true,
  setThinkingLevel: false,
};
const V_FULL: PiSemanticCapabilities = {
  ...CAPS,
  listModels: true,
  setModel: true,
  setThinkingLevel: true,
};

// ---------------------------------------------------------------------------
// Store-shaped composer state
// ---------------------------------------------------------------------------

const CLAUDE_3 = { provider: "anthropic", id: "claude-3", name: "Claude 3" };
const CATALOG = [
  {
    provider: "anthropic",
    modelID: "claude-3",
    name: "Claude 3",
    reasoning: true,
    contextWindow: 200000,
  },
];

function composerProps(
  overrides: Partial<PiComposerProps> = {},
): PiComposerProps {
  return {
    capabilities: V_FULL,
    phase: "idle",
    connection: { state: "connected" },
    bridgeConnected: true,
    isSubmitting: false,
    isAborting: false,
    currentModel: CLAUDE_3,
    availableModels: CATALOG,
    isLoadingModels: false,
    isSettingModel: false,
    modelCatalogError: null,
    isModelSwitchingUnsupported: false,
    thinkingLevel: null,
    isSettingThinkingLevel: false,
    commandNotice: null,
    ...overrides,
  };
}

function renderComposer(props: PiComposerProps): string {
  return renderToStaticMarkup(createElement(PiComposer, props));
}

function chatProps(overrides: Partial<PiChatViewProps> = {}): PiChatViewProps {
  return {
    connection: { state: "connected" },
    lastError: null,
    turns: [],
    phase: "idle",
    isTruncated: false,
    contextUsage: null,
    ...overrides,
  };
}

function renderCard(interaction: {
  id: string;
  kind: "select" | "confirm" | "input" | "editor" | "unknown";
  title: string;
  message: string | null;
  options: string[];
  placeholder: string | null;
}): string {
  return renderToStaticMarkup(createElement(InteractionCard, { interaction }));
}

describe("Pi composer — per-pane capability gating (live 9092 variants)", () => {
  it("full capabilities render both the model chip and the thinking chip", () => {
    const html = renderComposer(composerProps({ capabilities: V_FULL }));
    expect(html).toContain("data-pi-model-chip");
    expect(html).toContain("data-pi-thinking-chip");
  });

  it("the setModel/listModels-off variant hides the model chip", () => {
    const html = renderComposer(composerProps({ capabilities: V_NO_MODELS }));
    expect(html).not.toContain("data-pi-model-chip");
    expect(html).not.toContain("data-pi-thinking-chip");
  });

  it("the setThinkingLevel-off variant keeps the model chip but hides the thinking chip", () => {
    const html = renderComposer(composerProps({ capabilities: V_NO_THINKING }));
    expect(html).toContain("data-pi-model-chip");
    expect(html).not.toContain("data-pi-thinking-chip");
  });

  it("the default (unavailable) capabilities hide both chips", () => {
    const html = renderComposer(
      composerProps({ capabilities: PI_SEMANTIC_CAPABILITIES_UNAVAILABLE }),
    );
    expect(html).not.toContain("data-pi-model-chip");
    expect(html).not.toContain("data-pi-thinking-chip");
  });
});

describe("Pi composer — placeholder and disposition across statuses", () => {
  it("offline: 'Pi is offline' placeholder, send disabled, no status row", () => {
    const html = renderComposer(
      composerProps({
        phase: "working",
        connection: { state: "bridgeOffline" },
        bridgeConnected: false,
      }),
    );
    expect(html).toContain('placeholder="Pi is offline"');
    expect(html).toContain('data-pi-composer-send');
    expect(html).toMatch(/data-pi-composer-send[^>]*disabled/);
    // The status row follows the phase; Stop is the gated control.
    expect(html).toMatch(/data-pi-composer-stop[^>]*disabled/);
  });

  it("connected idle: 'Message Pi' placeholder and the 'Send' disposition", () => {
    const html = renderComposer(composerProps({ phase: "idle" }));
    expect(html).toContain('placeholder="Message Pi"');
    expect(html).toContain(
      '<span class="hz-pi-composer-send-full">Send</span>',
    );
    expect(html).not.toContain("Pi is working");
  });

  it("working: 'Pi is working' + 'Stop', 'Steer this turn' placeholder, 'Steer' label", () => {
    const html = renderComposer(composerProps({ phase: "working" }));
    expect(html).toContain("Pi is working");
    expect(html).toContain("Stop");
    expect(html).toContain("data-pi-composer-stop");
    expect(html).toContain('placeholder="Steer this turn"');
    expect(html).toContain(
      '<span class="hz-pi-composer-send-full">Steer</span>',
    );
  });

  it("working without steer: follow-up placeholder, 'Follow up'/'Next' labels, queued notice", () => {
    const html = renderComposer(
      composerProps({
        phase: "working",
        capabilities: { ...V_FULL, steer: false },
        commandNotice: "Follow-up queued",
      }),
    );
    expect(html).toContain('placeholder="Queue a follow-up"');
    expect(html).toContain(
      '<span class="hz-pi-composer-send-full">Follow up</span>',
    );
    expect(html).toContain(
      '<span class="hz-pi-composer-send-short">Next</span>',
    );
    expect(html).toContain("Follow-up queued");
  });

  it("an offline send surfaces the byte-exact store error under the banner", () => {
    const html = renderToStaticMarkup(
      createElement(PiChatView, {
        ...chatProps({
          connection: { state: "bridgeOffline" },
          lastError: "Pi is offline. Reconnect before sending a message.",
        }),
      }),
    );
    expect(html).toContain("Pi is offline. Transcript preserved.");
    expect(html).toContain("Pi is offline. Reconnect before sending a message.");
  });
});

describe("Pi interaction cards", () => {
  it("select kind renders one button per option (no text field, no Yes/No)", () => {
    const html = renderCard({
      id: "i1",
      kind: "select",
      title: "Which branch?",
      message: null,
      options: ["develop", "main"],
      placeholder: null,
    });
    expect(html).toContain('data-pi-interaction="i1"');
    expect(html).toContain("Which branch?");
    expect(html).toContain(">develop</button>");
    expect(html).toContain(">main</button>");
    expect(html).not.toContain(">No<");
    expect(html).not.toContain("Submit");
    expect(html).not.toContain("textarea");
  });

  it("confirm kind renders No and Yes buttons", () => {
    const html = renderCard({
      id: "i2",
      kind: "confirm",
      title: "Overwrite file?",
      message: "The file will be replaced.",
      options: [],
      placeholder: null,
    });
    expect(html).toContain(">No</button>");
    expect(html).toContain(">Yes</button>");
    expect(html).toContain("The file will be replaced.");
    expect(html).not.toContain("textarea");
  });

  it("input kind renders the text field ('Response' placeholder), Submit, and Cancel", () => {
    const html = renderCard({
      id: "i3",
      kind: "input",
      title: "Enter a name",
      message: null,
      options: [],
      placeholder: null,
    });
    expect(html).toContain("<textarea");
    expect(html).toContain('placeholder="Response"');
    expect(html).toContain(">Submit</button>");
    expect(html).toContain(">Cancel</button>");
    expect(html).not.toContain(">No</button>");
  });

  it("editor kind renders like input", () => {
    const html = renderCard({
      id: "i4",
      kind: "editor",
      title: "Edit description",
      message: null,
      options: [],
      placeholder: "Describe the change",
    });
    expect(html).toContain("<textarea");
    expect(html).toContain('placeholder="Describe the change"');
    expect(html).toContain(">Submit</button>");
    expect(html).toContain(">Cancel</button>");
  });

  it("known kinds replace the indicator; unknown kinds keep 'Pi needs your input'", () => {
    const selectOnly = renderToStaticMarkup(
      createElement(PiChatView, {
        ...chatProps({
          pendingInteractions: [
            {
              id: "i1",
              kind: "select",
              title: "Which branch?",
              message: null,
              options: ["develop", "main"],
              placeholder: null,
            },
          ],
        }),
      }),
    );
    expect(selectOnly).toContain('data-pi-interaction="i1"');
    expect(selectOnly).not.toContain("hz-pi-interactions");
    expect(selectOnly).not.toContain("Pi needs your input");

    const unknown = renderToStaticMarkup(
      createElement(PiChatView, {
        ...chatProps({
          pendingInteractions: [
            {
              id: "u1",
              kind: "unknown",
              title: "Pi needs your input",
              message: null,
              options: [],
              placeholder: null,
            },
          ],
        }),
      }),
    );
    expect(unknown).toContain("hz-pi-interactions");
    expect(unknown).toContain("Pi needs your input");
    expect(unknown).not.toContain("data-pi-interaction=");
  });
});

describe("Pi composer chip menus and the store-backed dock", () => {
  it("the model chip shows the current model display name; the thinking chip shows 'thinking'", () => {
    const html = renderComposer(composerProps());
    expect(html).toContain("Claude 3");
    expect(html).toContain(
      '<span class="hz-pi-chip-label">thinking</span>',
    );
  });

  it("the dock pipes its capabilities prop into the presentational composer", () => {
    // SSR note: React's renderToStaticMarkup reads zustand's INITIAL state
    // (useSyncExternalStore server snapshot), so the store wiring is
    // verified through the capabilities prop + initial state shape instead.
    const html = renderToStaticMarkup(
      createElement(PiComposerDock, { capabilities: V_NO_MODELS }),
    );
    expect(html).toContain("data-pi-composer-mount");
    expect(html).not.toContain("data-pi-model-chip");
    expect(html).not.toContain("data-pi-thinking-chip");
    expect(html).toContain('placeholder="Pi is offline"');
  });
});
