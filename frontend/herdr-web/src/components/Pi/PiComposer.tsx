/**
 * Pi composer (P8-run-B) — web port of the Pi-side of
 * `PromptComposerView` + `PiPromptComposerStatusBar` in herdr-harness-ios:
 *
 *  - status bar row while `phase === "working"`: "Pi is working" +
 *    disposition label + destructive "Stop" (piStore.abort →
 *    "Stop requested" notice)
 *  - status-aware placeholder (composerConfig: "Pi is offline" /
 *    "Message Pi" / "Steer this turn" / "Queue a follow-up")
 *  - send button per disposition (Send / Steer / Follow up; short labels
 *    Send / Steer / Next in narrow layouts via CSS)
 *  - command notices (e.g. "Follow-up queued") auto-clear after 2.5 s
 *    (Swift `.task(id: notice)` + 2.5 s sleep)
 *  - Enter (without Shift) and Cmd/Ctrl+Enter send; textarea auto-grows
 *    1–4 lines
 *
 * `PiComposer` is presentational (store-shaped props, store singleton for
 * actions); `PiComposerDock` subscribes to piStore and is what
 * PiChatView mounts at the composer point. An offline send is rejected by
 * the store, which sets lastError to
 * "Pi is offline. Reconnect before sending a message." (surfaced under
 * the connection banner by PiChatView).
 */
import { useEffect, useRef, useState } from "react";
import {
  piConnectionIsConnected,
  piPromptDispositionLabel,
  piPromptDispositionShortLabel,
  type PiAvailableModel,
  type PiConversationConnection,
  type PiConversationPhase,
  type PiModelIdentity,
  type PiSemanticCapabilities,
} from "../../pi/types";
import { piComposerConfiguration } from "../../pi/composerConfig";
import { ModelChip } from "./ModelChip";
import { ThinkingChip } from "./ThinkingChip";
import { usePiStore } from "../../store/piStore";

const NOTICE_CLEAR_MS = 2_500;

export interface PiComposerProps {
  /** Per-pane capability gate (the pane's pi_semantic, never global). */
  capabilities: PiSemanticCapabilities;
  phase: PiConversationPhase;
  connection: PiConversationConnection;
  bridgeConnected: boolean;
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
  commandNotice: string | null;
}

export function PiComposer(props: PiComposerProps) {
  const {
    capabilities,
    phase,
    connection,
    bridgeConnected,
    isSubmitting,
    isAborting,
    currentModel,
    availableModels,
    isLoadingModels,
    isSettingModel,
    modelCatalogError,
    isModelSwitchingUnsupported,
    thinkingLevel,
    isSettingThinkingLevel,
    commandNotice,
  } = props;

  const [draft, setDraft] = useState("");
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const isConnected = bridgeConnected && piConnectionIsConnected(connection);
  const config = piComposerConfiguration({
    capabilities,
    phase,
    isConnected,
    isSubmitting,
    isAborting,
    currentModel,
    availableModels,
    isLoadingModels,
    isSettingModel,
    modelCatalogError,
    isModelSwitchingUnsupported,
    thinkingLevel,
    isSettingThinkingLevel,
  });
  const disposition = config.preferredDisposition;
  const draftEmpty = draft.trim() === "";
  const canSend = isConnected && !isSubmitting && !draftEmpty;

  // Command notices auto-clear after 2.5 s (Swift PiChatView `.task(id:)`).
  useEffect(() => {
    if (commandNotice === null) return;
    const id = setTimeout(() => usePiStore.getState().clearCommandNotice(), NOTICE_CLEAR_MS);
    return () => clearTimeout(id);
  }, [commandNotice]);

  // Textarea auto-grows 1–4 lines.
  useEffect(() => {
    const el = textareaRef.current;
    if (el === null) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 4 * lineHeight(el))}px`;
  }, [draft]);

  const send = async (): Promise<void> => {
    if (!canSend) return;
    const text = draft.trim();
    const store = usePiStore.getState();
    const succeeded =
      disposition === "prompt"
        ? await store.prompt(text)
        : disposition === "steer"
          ? await store.steer(text)
          : await store.followUp(text);
    if (succeeded) setDraft("");
  };

  return (
    <div className="hz-pi-composer" data-pi-composer-mount>
      {phase === "working" && (
        <div className="hz-pi-composer-status" role="status">
          <span className="hz-pi-composer-working">Pi is working</span>
          <span className="hz-pi-composer-disposition">
            {piPromptDispositionLabel(disposition)}
          </span>
          <button
            type="button"
            className="hz-pi-composer-stop"
            data-pi-composer-stop
            disabled={!config.canAbort}
            onClick={() => void usePiStore.getState().abort()}
          >
            Stop
          </button>
        </div>
      )}
      <div className="hz-pi-composer-row">
        {capabilities.setModel && capabilities.listModels && (
          <ModelChip
            currentModel={currentModel}
            availableModels={availableModels}
            isLoadingModels={isLoadingModels}
            isSettingModel={isSettingModel}
            modelCatalogError={modelCatalogError}
            isModelSwitchingUnsupported={isModelSwitchingUnsupported}
            isEnabled={config.canSelectModel}
          />
        )}
        {capabilities.setThinkingLevel && (
          <ThinkingChip
            thinkingLevel={thinkingLevel}
            isSettingThinkingLevel={isSettingThinkingLevel}
            isEnabled={config.canSelectThinkingLevel}
          />
        )}
        <textarea
          ref={textareaRef}
          className="hz-pi-composer-input"
          rows={1}
          placeholder={config.placeholder(disposition)}
          value={draft}
          disabled={!isConnected}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && (event.metaKey || event.ctrlKey || !event.shiftKey)) {
              event.preventDefault();
              void send();
            }
          }}
        />
        <button
          type="button"
          className="hz-pi-composer-send"
          data-pi-composer-send
          disabled={!canSend}
          onClick={() => void send()}
        >
          <span className="hz-pi-composer-send-full">{piPromptDispositionLabel(disposition)}</span>
          <span className="hz-pi-composer-send-short">{piPromptDispositionShortLabel(disposition)}</span>
        </button>
      </div>
      {commandNotice !== null && (
        <p className="hz-pi-composer-notice" role="status">
          {commandNotice}
        </p>
      )}
    </div>
  );
}

function lineHeight(el: HTMLTextAreaElement): number {
  const value = Number.parseFloat(getComputedStyle(el).lineHeight);
  return Number.isFinite(value) && value > 0 ? value : 18;
}

/** Store-backed mount: pipes piStore state into the presentational composer. */
export function PiComposerDock({ capabilities }: { capabilities: PiSemanticCapabilities }) {
  const phase = usePiStore((state) => state.phase);
  const connection = usePiStore((state) => state.connection);
  const bridgeConnected = usePiStore((state) => state.bridgeConnected);
  const isSubmitting = usePiStore((state) => state.isSubmitting);
  const isAborting = usePiStore((state) => state.isAborting);
  const currentModel = usePiStore((state) => state.currentModel);
  const availableModels = usePiStore((state) => state.availableModels);
  const isLoadingModels = usePiStore((state) => state.isLoadingModels);
  const isSettingModel = usePiStore((state) => state.isSettingModel);
  const modelCatalogError = usePiStore((state) => state.modelCatalogError);
  const isModelSwitchingUnsupported = usePiStore((state) => state.isModelSwitchingUnsupported);
  const thinkingLevel = usePiStore((state) => state.thinkingLevel);
  const isSettingThinkingLevel = usePiStore((state) => state.isSettingThinkingLevel);
  const commandNotice = usePiStore((state) => state.commandNotice);

  return (
    <PiComposer
      capabilities={capabilities}
      phase={phase}
      connection={connection}
      bridgeConnected={bridgeConnected}
      isSubmitting={isSubmitting}
      isAborting={isAborting}
      currentModel={currentModel}
      availableModels={availableModels}
      isLoadingModels={isLoadingModels}
      isSettingModel={isSettingModel}
      modelCatalogError={modelCatalogError}
      isModelSwitchingUnsupported={isModelSwitchingUnsupported}
      thinkingLevel={thinkingLevel}
      isSettingThinkingLevel={isSettingThinkingLevel}
      commandNotice={commandNotice}
    />
  );
}
