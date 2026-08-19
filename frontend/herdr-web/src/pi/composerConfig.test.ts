/**
 * 1:1 port of the 10 @Test cases in
 * `herdr-harness-ios/herdr-harness-iosTests/PiPromptComposerConfigurationTests.swift`
 * (source of truth). Same test names, same assertions, same makeConfiguration
 * defaults.
 */
import { describe, expect, it } from "vitest";
import { piComposerConfiguration } from "./composerConfig";
import type { PiComposerConfigurationInput } from "./composerConfig";
import type {
  PiAvailableModel,
  PiConversationPhase,
  PiSemanticCapabilities,
} from "./types";

describe("Pi prompt composer configuration", () => {
  it("Idle Pi sessions accept a standard prompt", () => {
    const configuration = makeConfiguration("idle");

    expect(configuration.availableDispositions).toEqual(["prompt"]);
    expect(configuration.preferredDisposition).toBe("prompt");
    expect(configuration.placeholder("prompt")).toBe("Message Pi");
    expect(configuration.canAbort).toBe(false);
  });

  it("Working Pi sessions offer steer and follow-up without disrupting the current turn", () => {
    const configuration = makeConfiguration("working");

    expect(configuration.availableDispositions).toEqual(["steer", "followUp"]);
    expect(configuration.preferredDisposition).toBe("steer");
    expect(configuration.placeholder("steer")).toBe("Steer this turn");
    expect(configuration.placeholder("followUp")).toBe("Queue a follow-up");
    expect(configuration.canAbort).toBe(true);
  });

  it("Prompt remains a safe fallback when live dispositions are unavailable", () => {
    const configuration = makeConfiguration("working", {
      capabilities: {
        prompt: true,
        steer: false,
        followUp: false,
        abort: false,
        listModels: false,
        setModel: false,
        setThinkingLevel: false,
        interactionResponse: false,
      },
    });

    expect(configuration.availableDispositions).toEqual(["prompt"]);
    expect(configuration.canAbort).toBe(false);
  });

  it("An offline bridge disables submission and stop controls", () => {
    const configuration = makeConfiguration("working", { isConnected: false });

    expect(configuration.availableDispositions).toEqual([]);
    expect(configuration.placeholder("steer")).toBe("Pi is offline");
    expect(configuration.canAbort).toBe(false);
  });

  it("Known models remain read-only when model capabilities are unavailable", () => {
    const configuration = makeConfiguration("idle", {
      capabilities: {
        prompt: true,
        steer: true,
        followUp: true,
        abort: true,
        listModels: false,
        setModel: false,
        setThinkingLevel: false,
        interactionResponse: true,
      },
      currentModel: { provider: "anthropic", id: "claude-3", name: "Claude 3" },
    });

    expect(configuration.supportsModelMenu).toBe(false);
  });

  it("Available model capabilities support the model menu", () => {
    const configuration = makeConfiguration("idle");

    expect(configuration.supportsModelMenu).toBe(true);
  });

  it("Unsupported model switching overrides available model capabilities", () => {
    const configuration = makeConfiguration("idle", {
      isModelSwitchingUnsupported: true,
    });

    expect(configuration.supportsModelMenu).toBe(false);
  });

  it("Thinking capability controls whether the thinking menu is supported", () => {
    const configuration = makeConfiguration("idle", {
      capabilities: {
        prompt: true,
        steer: true,
        followUp: true,
        abort: true,
        listModels: true,
        setModel: true,
        setThinkingLevel: false,
        interactionResponse: true,
      },
    });

    expect(configuration.supportsThinkingMenu).toBe(false);
  });

  it("Known non-reasoning models do not support the thinking menu", () => {
    const configuration = makeConfiguration("idle", {
      currentModel: { provider: "openai", id: "gpt-5", name: "GPT-5" },
      availableModels: [
        {
          provider: "openai",
          modelID: "gpt-5",
          name: "GPT-5",
          reasoning: false,
          contextWindow: null,
        },
      ],
    });

    expect(configuration.supportsThinkingMenu).toBe(false);
  });

  it("Reasoning models support the thinking menu", () => {
    const configuration = makeConfiguration("idle", {
      currentModel: { provider: "openai", id: "gpt-5", name: "GPT-5" },
      availableModels: [
        {
          provider: "openai",
          modelID: "gpt-5",
          name: "GPT-5",
          reasoning: true,
          contextWindow: null,
        },
      ],
    });

    expect(configuration.supportsThinkingMenu).toBe(true);
  });
});

const DEFAULT_CAPABILITIES: PiSemanticCapabilities = {
  prompt: true,
  steer: true,
  followUp: true,
  abort: true,
  listModels: true,
  setModel: true,
  setThinkingLevel: true,
  interactionResponse: true,
};

function makeConfiguration(
  phase: PiConversationPhase,
  overrides: Partial<
    Pick<
      PiComposerConfigurationInput,
      | "capabilities"
      | "isConnected"
      | "currentModel"
      | "thinkingLevel"
      | "isSettingThinkingLevel"
      | "availableModels"
      | "isModelSwitchingUnsupported"
    >
  > = {},
) {
  return piComposerConfiguration({
    capabilities: overrides.capabilities ?? DEFAULT_CAPABILITIES,
    phase,
    isConnected: overrides.isConnected ?? true,
    isSubmitting: false,
    isAborting: false,
    currentModel: overrides.currentModel ?? null,
    availableModels: overrides.availableModels ?? ([] as PiAvailableModel[]),
    isLoadingModels: false,
    isSettingModel: false,
    modelCatalogError: null,
    isModelSwitchingUnsupported: overrides.isModelSwitchingUnsupported ?? false,
    thinkingLevel: overrides.thinkingLevel ?? null,
    isSettingThinkingLevel: overrides.isSettingThinkingLevel ?? false,
  });
}
