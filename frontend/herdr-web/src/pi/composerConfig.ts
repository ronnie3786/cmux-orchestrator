/**
 * Deterministic TS port of `herdr-harness-ios/Views/Pane/
 * PiPromptComposerConfiguration.swift` (source of truth) — the status →
 * placeholder/disposition mapping for the Pi composer.
 *
 * The Swift struct's action closures (`submit`, `abort`, `selectModel`,
 * `retryLoadModels`, `selectThinkingLevel`) are intentionally not ported:
 * the web components call the piStore command methods directly, so only the
 * pure disposition/status/menu computations live here.
 */

import type {
  PiAvailableModel,
  PiConversationPhase,
  PiModelIdentity,
  PiPromptDisposition,
  PiSemanticCapabilities,
} from "./types";

export interface PiComposerConfigurationInput {
  capabilities: PiSemanticCapabilities;
  phase: PiConversationPhase;
  isConnected: boolean;
  isSubmitting: boolean;
  isAborting: boolean;
  currentModel: PiModelIdentity | null;
  availableModels: PiAvailableModel[];
  isLoadingModels: boolean;
  isSettingModel: boolean;
  modelCatalogError: string | null;
  isModelSwitchingUnsupported: boolean;
  thinkingLevel: string | null;
  isSettingThinkingLevel: boolean;
}

export interface PiComposerConfiguration extends PiComposerConfigurationInput {
  availableDispositions: PiPromptDisposition[];
  preferredDisposition: PiPromptDisposition;
  canAbort: boolean;
  canSelectModel: boolean;
  canSelectThinkingLevel: boolean;
  supportsModelMenu: boolean;
  supportsThinkingMenu: boolean;
  placeholder: (disposition: PiPromptDisposition) => string;
}

/** Mirror of `PiPromptComposerConfiguration.availableDispositions`. */
export function piComposerAvailableDispositions(
  input: Pick<
    PiComposerConfigurationInput,
    "capabilities" | "phase" | "isConnected"
  >,
): PiPromptDisposition[] {
  if (!input.isConnected) return [];
  if (input.phase !== "working") {
    return input.capabilities.prompt ? ["prompt"] : [];
  }
  const dispositions: PiPromptDisposition[] = [];
  if (input.capabilities.steer) dispositions.push("steer");
  if (input.capabilities.followUp) dispositions.push("followUp");
  if (dispositions.length === 0 && input.capabilities.prompt) dispositions.push("prompt");
  return dispositions;
}

/** Mirror of `PiPromptComposerConfiguration` (computed fields only). */
export function piComposerConfiguration(
  input: PiComposerConfigurationInput,
): PiComposerConfiguration {
  const availableDispositions = piComposerAvailableDispositions(input);
  return {
    ...input,
    availableDispositions,
    preferredDisposition: availableDispositions[0] ?? "prompt",
    canAbort:
      input.phase === "working" &&
      input.isConnected &&
      input.capabilities.abort &&
      !input.isAborting,
    canSelectModel:
      input.capabilities.setModel && input.isConnected && !input.isSettingModel,
    canSelectThinkingLevel:
      input.capabilities.setThinkingLevel &&
      input.isConnected &&
      !input.isSettingThinkingLevel,
    supportsModelMenu:
      input.capabilities.listModels &&
      input.capabilities.setModel &&
      !input.isModelSwitchingUnsupported,
    // Swift: unknown current model or missing `reasoning` field → true.
    supportsThinkingMenu:
      input.capabilities.setThinkingLevel &&
      (input.currentModel === null ||
        (input.availableModels.find(
          (model) =>
            model.provider === input.currentModel?.provider &&
            model.modelID === input.currentModel?.id,
        )?.reasoning ??
          true)),
    placeholder: (disposition) => {
      if (!input.isConnected) return "Pi is offline";
      switch (disposition) {
        case "prompt":
          return "Message Pi";
        case "steer":
          return "Steer this turn";
        case "followUp":
          return "Queue a follow-up";
      }
    },
  };
}
