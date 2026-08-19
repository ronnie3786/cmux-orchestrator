/**
 * Model picker chip (P8-run-B) — web port of
 * `herdr-harness-ios/Views/Pane/PiModelPickerChip.swift`: chip label =
 * current model display name (lowercase "model" fallback), popover lists
 * models grouped by provider (sorted), select → piStore.setModel.
 *
 * Menu states, byte-exact: "Loading models…" / "No models available" /
 * the catalog error + "Retry" (piStore.retryLoadModels) / 501 →
 * "Model switching isn't supported by this Pi session".
 */
import { useState } from "react";
import {
  piAvailableModelDisplayName,
  piAvailableModelID,
  piModelIdentityDisplayName,
} from "../../pi/types";
import { piModelIsCurrent, piModelProviderGroups } from "../../pi/modelCatalog";
import type { PiAvailableModel, PiModelIdentity } from "../../pi/types";
import { usePiStore } from "../../store/piStore";

const MODEL_501_MESSAGE = "Model switching isn't supported by this Pi session";

export interface ModelChipProps {
  currentModel: PiModelIdentity | null;
  availableModels: PiAvailableModel[];
  isLoadingModels: boolean;
  isSettingModel: boolean;
  modelCatalogError: string | null;
  isModelSwitchingUnsupported: boolean;
  /** Swift `isEnabled` = configuration.canSelectModel. */
  isEnabled: boolean;
}

export function ModelChip({
  currentModel,
  availableModels,
  isLoadingModels,
  isSettingModel,
  modelCatalogError,
  isModelSwitchingUnsupported,
  isEnabled,
}: ModelChipProps) {
  const [open, setOpen] = useState(false);
  const groups = piModelProviderGroups(availableModels);

  const selectModel = async (model: PiAvailableModel): Promise<void> => {
    setOpen(false);
    await usePiStore.getState().setModel(model.provider, model.modelID);
  };

  return (
    <span className="hz-pi-chip-wrap" data-pi-model-chip>
      <button
        type="button"
        className={`hz-pi-chip${isEnabled ? "" : " hz-pi-chip-disabled"}`}
        aria-expanded={open}
        aria-label={`Model: ${currentModel !== null ? piModelIdentityDisplayName(currentModel) : "unknown"}`}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="hz-pi-chip-icon" aria-hidden>
          {isSettingModel ? "…" : "⬡"}
        </span>
        <span className="hz-pi-chip-label">
          {currentModel !== null ? piModelIdentityDisplayName(currentModel) : "model"}
        </span>
        <span className="hz-pi-chip-caret" aria-hidden>
          ▾
        </span>
      </button>
      {open && (
        <span className="hz-pi-chip-menu" role="menu">
          {isModelSwitchingUnsupported ? (
            <span className="hz-pi-chip-muted" role="disabled">
              {MODEL_501_MESSAGE}
            </span>
          ) : isLoadingModels ? (
            <span className="hz-pi-chip-muted" role="disabled">
              Loading models…
            </span>
          ) : modelCatalogError !== null ? (
            <>
              <span className="hz-pi-chip-error" role="alert">
                {modelCatalogError}
              </span>
              <button
                type="button"
                className="hz-pi-chip-retry"
                onClick={() => void usePiStore.getState().retryLoadModels()}
              >
                Retry
              </button>
            </>
          ) : groups.length === 0 ? (
            <span className="hz-pi-chip-muted" role="disabled">
              No models available
            </span>
          ) : (
            groups.map((group) => (
              <span key={group.provider} className="hz-pi-chip-group">
                <span className="hz-pi-chip-provider">{group.provider}</span>
                {group.models.map((model) => (
                  <button
                    key={piAvailableModelID(model)}
                    type="button"
                    role="menuitem"
                    className={`hz-pi-chip-item${
                      piModelIsCurrent(currentModel, model)
                        ? " hz-pi-chip-item-current"
                        : ""
                    }`}
                    onClick={() => void selectModel(model)}
                  >
                    {piAvailableModelDisplayName(model)}
                  </button>
                ))}
              </span>
            ))
          )}
        </span>
      )}
    </span>
  );
}
