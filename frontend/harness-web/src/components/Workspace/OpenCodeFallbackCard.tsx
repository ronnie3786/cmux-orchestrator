/**
 * OpenCode terminal fallback card — port of
 * cmux-harness-ios/Views/Workspace/OpenCodeTerminalFallbackCard.swift.
 *
 * Shown when the server feed has no native item for the selected session but
 * the terminal detector found an active OpenCode prompt (older OpenCode
 * versions / plugin not installed). Controls send real keystrokes to the
 * terminal; the question path computes the exact key sequence iOS uses:
 * [down, up] + down x selectedOptionIndex + enter.
 *
 * The integration upsell ("Enable native controls") is folded into this card,
 * matching its iOS placement (integrationSetup is part of the permission
 * fallback content, not a separate card).
 */

import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import {
  ArrowDown,
  ArrowLeft,
  ArrowRight,
  ArrowUp,
  Circle,
  CircleCheck,
  CornerDownLeft,
  Hand,
  Hourglass,
  Info,
  List,
  MessageCircleQuestion,
  MoveRight,
  ShieldCheck,
  Sparkles,
  SquareX,
  TriangleAlert,
} from "lucide-react";

import type { OpenCodeIntegrationResponse } from "../../api/types";
import type {
  OpenCodeTerminalInteraction,
} from "../../terminal/detector";
import { interactionPromptID } from "../../terminal/detector";

export interface OpenCodeFallbackCardProps {
  interaction: OpenCodeTerminalInteraction;
  fallbackNote: string | null;
  integrationStatus: OpenCodeIntegrationResponse | null;
  isInstallingIntegration: boolean;
  onSendKey: (key: string) => void;
  onSendKeys: (keys: string[]) => void;
  onInstallIntegration: () => void;
}

// Key -> icon mapping (mirror of HarnessKey.systemImage).
function keyIcon(key: string): ReactNode {
  switch (key) {
    case "up":
      return <ArrowUp size={13} />;
    case "down":
      return <ArrowDown size={13} />;
    case "left":
      return <ArrowLeft size={13} />;
    case "right":
      return <ArrowRight size={13} />;
    case "tab":
      return <MoveRight size={13} />;
    case "enter":
      return <CornerDownLeft size={13} />;
    case "escape":
      return <SquareX size={13} />;
    default:
      return null;
  }
}

type ButtonRole = "primary" | "secondary" | "destructive" | "neutral" | "attention";

/** Port of OpenCodeActionButton (icon + optional title). */
function KeyButton({
  label,
  key,
  role,
  showsTitle = true,
  disabled,
  onClick,
}: {
  label: string;
  key: string;
  role: ButtonRole;
  showsTitle?: boolean;
  disabled?: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      className={`oc-btn oc-btn-${role}`}
      disabled={disabled}
      onClick={onClick}
      title={label}
      aria-label={label}
    >
      {keyIcon(key)}
      {showsTitle && <span>{label}</span>}
    </button>
  );
}

function FallbackMessage({ note }: { note: string | null }) {
  if (!note || note.length === 0) return null;
  return (
    <div className="oc-fallback-note">
      <Info size={13} aria-hidden />
      <span>{note}</span>
    </div>
  );
}

/** Port of integrationSetup (iOS places this in the permission content). */
function IntegrationSetup({
  status,
  isInstalling,
  onInstall,
}: {
  status: OpenCodeIntegrationResponse | null;
  isInstalling: boolean;
  onInstall: () => void;
}) {
  if (status?.installed === true) {
    const text =
      status.needsRestart === true
        ? "Native controls enabled. Restart OpenCode to activate them."
        : "Native controls installed. Restart OpenCode if this prompt stays visible.";
    return (
      <div className="oc-integration-installed">
        <ShieldCheck size={13} aria-hidden />
        <span>{text}</span>
      </div>
    );
  }
  if (status?.cmuxAvailable === true) {
    return (
      <button
        type="button"
        className="oc-btn oc-btn-attention"
        disabled={isInstalling}
        onClick={onInstall}
        aria-label="Enable native controls"
      >
        {isInstalling ? <Hourglass size={13} /> : <Sparkles size={13} />}
        <span>{isInstalling ? "Enabling native controls…" : "Enable native controls"}</span>
      </button>
    );
  }
  const summary = status?.summary?.trim() ?? "";
  if (summary.length > 0) {
    return (
      <div className="oc-integration-warning">
        <TriangleAlert size={13} aria-hidden />
        <span>{summary}</span>
      </div>
    );
  }
  return null;
}

/** Port of manualActions(rejectLabel:). */
function ManualActions({
  axis,
  rejectLabel,
  onSendKey,
}: {
  axis: OpenCodeTerminalInteraction["navigationAxis"];
  rejectLabel: string;
  onSendKey: (key: string) => void;
}) {
  const previousKey = axis === "horizontal" ? "left" : "up";
  const nextKey = axis === "horizontal" ? "right" : "down";
  return (
    <div className="oc-actions-row">
      <KeyButton label="Previous" key={previousKey} role="neutral" showsTitle={false} onClick={() => onSendKey(previousKey)} />
      <KeyButton label="Next" key={nextKey} role="neutral" showsTitle={false} onClick={() => onSendKey(nextKey)} />
      <span className="oc-actions-spacer" />
      <KeyButton label="Confirm" key="enter" role="primary" onClick={() => onSendKey("enter")} />
      <KeyButton label={rejectLabel} key="escape" role="destructive" onClick={() => onSendKey("escape")} />
    </div>
  );
}

function InteractionDetail({ interaction }: { interaction: OpenCodeTerminalInteraction }) {
  if (interaction.detail.length === 0) return null;
  return <div className={`oc-detail-text${interaction.kind === "question" ? " oc-detail-bold" : ""}`}>{interaction.detail}</div>;
}

function ReviewRows({ interaction }: { interaction: OpenCodeTerminalInteraction }) {
  return (
    <div className="oc-review-rows">
      {interaction.reviewItems.map((item, index) => (
        <div key={`${item.label}-${index}`} className="oc-review-row">
          <div className="oc-review-header">{item.label}</div>
          <div className="oc-review-answer">
            <CircleCheck size={14} aria-hidden />
            <span>{item.value}</span>
          </div>
        </div>
      ))}
    </div>
  );
}

export function OpenCodeFallbackCard({
  interaction,
  fallbackNote,
  integrationStatus,
  isInstallingIntegration,
  onSendKey,
  onSendKeys,
  onInstallIntegration,
}: OpenCodeFallbackCardProps) {
  const [selectedOptionIndex, setSelectedOptionIndex] = useState(0);

  // Mirror iOS .onChange(of: interaction.promptID).
  const promptID = interactionPromptID(interaction);
  useEffect(() => {
    setSelectedOptionIndex(0);
  }, [promptID]);

  const headerIcon =
    interaction.kind === "permission" ? (
      <Hand size={16} />
    ) : interaction.kind === "question" ? (
      <MessageCircleQuestion size={16} />
    ) : (
      <CircleCheck size={16} />
    );

  const subtitle =
    interaction.kind === "permission"
      ? "OpenCode terminal · Manual controls"
      : "OpenCode terminal · Remote questions";

  // Port of submitSelectedOption: each OpenCode question opens on its first
  // row; down+up makes the starting point explicit, then the remaining downs
  // select the checked row before Enter advances.
  const submitSelectedOption = () => {
    if (selectedOptionIndex < 0 || selectedOptionIndex >= interaction.options.length) return;
    const selectionKeys = ["down", "up", ...Array.from({ length: selectedOptionIndex }, () => "down")];
    onSendKeys([...selectionKeys, "enter"]);
  };

  return (
    <div className="oc-card oc-fallback-card">
      <div className="oc-card-header">
        <span className="oc-card-icon" aria-hidden>
          {headerIcon}
        </span>
        <div className="oc-card-header-text">
          <div className="oc-card-title">{interaction.title}</div>
          <div className="oc-card-subtitle">{subtitle}</div>
        </div>
      </div>

      <div className="oc-section">
        {interaction.kind === "permission" ? (
          <>
            <InteractionDetail interaction={interaction} />
            {interaction.options.length > 0 && (
              <div className="oc-choices-label">
                <List size={13} aria-hidden />
                <span className="oc-choices-label-title">Choices</span>
                <span className="oc-choices-label-text">{interaction.options.join(" · ")}</span>
              </div>
            )}
            <div className="oc-hint-text">Choose with Previous or Next, then confirm.</div>
            <FallbackMessage note={fallbackNote} />
            <IntegrationSetup
              status={integrationStatus}
              isInstalling={isInstallingIntegration}
              onInstall={onInstallIntegration}
            />
            <ManualActions axis={interaction.navigationAxis} rejectLabel="Reject" onSendKey={onSendKey} />
          </>
        ) : interaction.kind === "question" ? (
          fallbackNote !== null ? (
            <>
              <InteractionDetail interaction={interaction} />
              <div className="oc-choices-label">
                <List size={13} aria-hidden />
                <span className="oc-choices-label-text">{interaction.options.join(" · ")}</span>
              </div>
              <FallbackMessage note={fallbackNote} />
              <ManualActions axis={interaction.navigationAxis} rejectLabel="Dismiss" onSendKey={onSendKey} />
            </>
          ) : (
            <>
              <InteractionDetail interaction={interaction} />
              <div className="oc-choices">
                {interaction.options.map((option, index) => (
                  <button
                    key={`${option}-${index}`}
                    type="button"
                    className={`oc-choice${selectedOptionIndex === index ? " oc-choice-selected" : ""}`}
                    onClick={() => setSelectedOptionIndex(index)}
                    aria-pressed={selectedOptionIndex === index}
                  >
                    <span className="oc-choice-icon" aria-hidden>
                      {selectedOptionIndex === index ? <CircleCheck size={15} /> : <Circle size={15} />}
                    </span>
                    <span className="oc-choice-text">
                      <span className="oc-choice-label">{option}</span>
                    </span>
                  </button>
                ))}
              </div>
              <div className="oc-hint-text">
                Tap a choice, then tap Next. Your selection stays visible here while cmux advances OpenCode.
              </div>
              <div className="oc-actions-row">
                <KeyButton
                  label="Next"
                  key="right"
                  role="primary"
                  disabled={selectedOptionIndex < 0 || selectedOptionIndex >= interaction.options.length}
                  onClick={submitSelectedOption}
                />
                <KeyButton label="Dismiss" key="escape" role="destructive" onClick={() => onSendKey("escape")} />
              </div>
            </>
          )
        ) : (
          <>
            <InteractionDetail interaction={interaction} />
            <ReviewRows interaction={interaction} />
            <div className="oc-actions-row">
              <KeyButton label="Edit answers" key="tab" role="neutral" onClick={() => onSendKey("tab")} />
              <KeyButton label="Submit" key="enter" role="primary" onClick={() => onSendKey("enter")} />
              <KeyButton label="Dismiss" key="escape" role="destructive" onClick={() => onSendKey("escape")} />
            </div>
          </>
        )}
      </div>
    </div>
  );
}
