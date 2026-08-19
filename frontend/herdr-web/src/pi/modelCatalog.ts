/**
 * Model-catalog presentation helpers (P8-run-B). The decoders and
 * identity/display-name functions the ported PiModelCatalogTests exercise
 * already live in `./types.ts` (deterministic port of the Swift model
 * files); this module adds the picker-level logic that
 * `PiModelPickerChip.swift` computes inline: provider grouping (sorted,
 * per the Swift `groupedProviders`) and current-model resolution.
 */

import {
  piAvailableModelID,
  piAvailableModelDisplayName,
  piModelIdentityDisplayName,
  piThinkingLevelDisplayName,
  PI_THINKING_LEVELS,
} from "./types";
import type { PiAvailableModel, PiModelIdentity } from "./types";

export {
  piAvailableModelID,
  piAvailableModelDisplayName,
  piModelIdentityDisplayName,
  piThinkingLevelDisplayName,
  PI_THINKING_LEVELS,
};

export interface PiModelProviderGroup {
  provider: string;
  models: PiAvailableModel[];
}

/** Swift `groupedProviders` + `modelsByProvider` (providers sorted). */
export function piModelProviderGroups(models: PiAvailableModel[]): PiModelProviderGroup[] {
  const byProvider = new Map<string, PiAvailableModel[]>();
  for (const model of models) {
    const list = byProvider.get(model.provider);
    if (list === undefined) byProvider.set(model.provider, [model]);
    else list.push(model);
  }
  return [...byProvider.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([provider, grouped]) => ({ provider, models: grouped }));
}

/** Swift `PiModelPickerChip.isCurrent`. */
export function piModelIsCurrent(
  current: PiModelIdentity | null,
  candidate: PiAvailableModel,
): boolean {
  return (
    current !== null && current.provider === candidate.provider && current.id === candidate.modelID
  );
}

/** Swift `PiThinkingLevelChip.displayText` ("thinking" when none set). */
export function piThinkingLevelChipText(level: string | null): string {
  if (level === null) return "thinking";
  return (PI_THINKING_LEVELS as readonly string[]).includes(level)
    ? piThinkingLevelDisplayName(level as (typeof PI_THINKING_LEVELS)[number])
    : level;
}
