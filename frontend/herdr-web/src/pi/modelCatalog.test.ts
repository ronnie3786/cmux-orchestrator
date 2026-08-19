/**
 * 1:1 port of the 5 @Test cases in
 * `herdr-harness-ios/herdr-harness-iosTests/PiModelCatalogTests.swift`
 * (source of truth). Same test names and assertions. The decoders /
 * identity helpers under test were already ported in `./types.ts`;
 * `./modelCatalog.ts` re-exports them plus the picker-level grouping.
 */
import { describe, expect, it } from "vitest";
import {
  decodePiAvailableModel,
  decodePiModelCatalogResponse,
  piModelIdentityFrom,
} from "./types";
import {
  piAvailableModelID,
  piModelIdentityDisplayName,
  piModelIsCurrent,
  piModelProviderGroups,
  PI_THINKING_LEVELS,
} from "./modelCatalog";

describe("Pi model catalog", () => {
  it("Thinking level raw values match Pi's canonical order", () => {
    expect([...PI_THINKING_LEVELS]).toEqual([
      "off",
      "minimal",
      "low",
      "medium",
      "high",
      "xhigh",
      "max",
    ]);
  });

  it("Model identity accepts canonical and fallback identifiers", () => {
    const named = piModelIdentityFrom({
      provider: "anthropic",
      id: "claude-3",
      name: "Claude 3",
    });
    const fallback = piModelIdentityFrom({
      provider: "openai",
      modelId: "gpt-5",
      name: "",
    });

    expect(named).not.toBeNull();
    expect(named?.provider).toBe("anthropic");
    expect(named?.id).toBe("claude-3");
    expect(named?.name).toBe("Claude 3");
    expect(piModelIdentityDisplayName(named!)).toBe("Claude 3");
    expect(fallback).not.toBeNull();
    expect(fallback?.id).toBe("gpt-5");
    expect(piModelIdentityDisplayName(fallback!)).toBe("gpt-5");
    expect(piModelIdentityFrom(null)).toBeNull();
    expect(piModelIdentityFrom(undefined)).toBeNull();
  });

  it("Available models decode wire identifiers and context aliases", () => {
    const snakeCase = decodePiAvailableModel({
      provider: "anthropic",
      id: "claude-3",
      context_window: 200000,
    });
    const camelCase = decodePiAvailableModel({
      provider: "openai",
      id: "gpt-5",
      contextWindow: 128000,
    });

    expect(snakeCase.modelID).toBe("claude-3");
    expect(snakeCase.contextWindow).toBe(200000);
    expect(piAvailableModelID(snakeCase)).toBe("anthropic/claude-3");
    expect(camelCase.contextWindow).toBe(128000);
  });

  it("Catalog response decodes the bridge success envelope", () => {
    const success = decodePiModelCatalogResponse({
      success: true,
      result: {
        models: [
          {
            provider: "anthropic",
            id: "claude-3",
            name: "Claude 3",
            reasoning: true,
            context_window: 200000,
          },
        ],
        current: { provider: "anthropic", id: "claude-3" },
      },
    });

    expect(success.accepted).toBe(true);
    expect(success.models).toHaveLength(1);
    expect(success.models[0].reasoning).toBe(true);
    expect(success.models[0].contextWindow).toBe(200000);
    expect(success.current?.id).toBe("claude-3");
  });

  it("Catalog response also tolerates a legacy ok key", () => {
    const success = decodePiModelCatalogResponse({
      ok: true,
      result: { models: [], current: null },
    });

    expect(success.accepted).toBe(true);
    expect(success.models).toEqual([]);
    expect(success.current).toBeNull();
  });

  it("Picker-level helpers: provider grouping (sorted) and current-model resolution", () => {
    const models = [
      { provider: "openai", modelID: "gpt-5", name: "GPT-5", reasoning: true, contextWindow: null },
      { provider: "anthropic", modelID: "claude-3", name: "Claude 3", reasoning: true, contextWindow: 200000 },
      { provider: "openai", modelID: "gpt-5-mini", name: null, reasoning: false, contextWindow: null },
    ];

    const groups = piModelProviderGroups(models);
    expect(groups.map((group) => group.provider)).toEqual(["anthropic", "openai"]);
    expect(groups[1].models.map((model) => model.modelID)).toEqual(["gpt-5", "gpt-5-mini"]);

    const current = { provider: "openai", id: "gpt-5", name: "GPT-5" };
    expect(
      models.map((model) => piModelIsCurrent(current, model)),
    ).toEqual([true, false, false]);
    expect(piModelIsCurrent(null, models[0])).toBe(false);
  });
});
