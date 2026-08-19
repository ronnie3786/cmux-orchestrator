/**
 * Native feed interaction card — port of
 * cmux-harness-ios/Views/Workspace/FeedInteractionCard.swift
 * (plus OpenCodeInteractionHeader / OpenCodeChoiceRow / OpenCodeActionButton /
 * openCodeInteractionCardChrome from the same folder).
 *
 * Shown for the selected session when the cmux feed has a pending item that
 * supports native reply (permission / question / plan). Questions render the
 * multi-question wizard with the review-answers step, exactly like iOS:
 * synthesized question fallback from item.options, "Next" disabled until the
 * current question has an answer, "Review answers" disabled until ALL
 * questions have answers.
 */

import { useEffect, useState } from "react";
import type { Dispatch, ReactNode, SetStateAction } from "react";
import {
  ArrowDown,
  ArrowUp,
  Check,
  ChevronLeft,
  ChevronRight,
  Circle,
  CircleCheck,
  CornerDownLeft,
  FilePen,
  FileText,
  FolderOpen,
  Hand,
  KeyRound,
  ListChecks,
  Loader2,
  MessageCircleQuestion,
  MessageCircleWarning,
  Send,
  ShieldCheck,
  Terminal,
  X,
} from "lucide-react";

import type { FeedItem, FeedOption, FeedQuestion } from "../../api/types";
import { feedItemDisplayTitle, feedItemSummary } from "../../lib/feed";

export type FeedReplyAction = "approve" | "deny" | "answer" | "manual";
export type FeedReplyMode = "once" | "always" | "autoAccept" | "manual" | "deny";

export interface FeedInteractionCardProps {
  item: FeedItem;
  isSubmitting: boolean;
  onReply: (action: FeedReplyAction, mode: FeedReplyMode | null, selections: string[] | null) => void;
  onSendKey: (key: string) => void;
}

// --- shared building blocks (ports of the OpenCode* views) -------------------

type ButtonRole = "primary" | "secondary" | "destructive" | "neutral" | "attention";

/** Port of OpenCodeActionButton. */
function ActionButton({
  title,
  icon,
  role,
  fillsWidth = true,
  disabled,
  onClick,
}: {
  title: string;
  icon: ReactNode;
  role: ButtonRole;
  fillsWidth?: boolean;
  disabled?: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      className={`oc-btn oc-btn-${role}${fillsWidth ? " oc-btn-fill" : ""}`}
      disabled={disabled}
      onClick={onClick}
    >
      {icon}
      <span>{title}</span>
    </button>
  );
}

/** Port of OpenCodeInteractionHeader. */
function InteractionHeader({
  title,
  subtitle,
  icon,
  isBusy,
}: {
  title: string;
  subtitle: string;
  icon: ReactNode;
  isBusy: boolean;
}) {
  return (
    <div className="oc-card-header">
      <span className="oc-card-icon" aria-hidden>
        {icon}
      </span>
      <div className="oc-card-header-text">
        <div className="oc-card-title">{title}</div>
        <div className="oc-card-subtitle">{subtitle}</div>
      </div>
      {isBusy && <Loader2 size={14} className="oc-card-spinner" aria-label="Sending response" />}
    </div>
  );
}

/** Port of OpenCodeChoiceRow. */
function ChoiceRow({
  option,
  isSelected,
  onSelect,
}: {
  option: FeedOption;
  isSelected: boolean;
  onSelect: () => void;
}) {
  const detail = option.description?.trim() ?? "";
  return (
    <button
      type="button"
      className={`oc-choice${isSelected ? " oc-choice-selected" : ""}`}
      onClick={onSelect}
      aria-label={option.label}
      aria-pressed={isSelected}
    >
      <span className="oc-choice-icon" aria-hidden>
        {isSelected ? <CircleCheck size={15} /> : <Circle size={15} />}
      </span>
      <span className="oc-choice-text">
        <span className="oc-choice-label">{option.label}</span>
        {detail.length > 0 && <span className="oc-choice-detail">{detail}</span>}
      </span>
    </button>
  );
}

// --- helpers (ports of the FeedInteractionCard computed props) ---------------

function trimmed(value: string | null | undefined): string | null {
  const v = (value ?? "").trim();
  return v.length > 0 ? v : null;
}

/** Mirror of humanized(_:): "file_write" -> "File Write". */
function humanized(value: string): string {
  return value
    .replace(/_/g, " ")
    .replace(/-/g, " ")
    .split(" ")
    .filter(Boolean)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(" ");
}

/** Mirror of permissionScopeLabel. */
function permissionScopeLabel(item: FeedItem): string {
  const permissionType = trimmed(item.permissionType);
  return permissionType ? humanized(permissionType) : "Requested scope";
}

/** Mirror of permissionScopeSymbol. */
function permissionScopeSymbol(item: FeedItem): ReactNode {
  switch (item.permissionType?.toLowerCase()) {
    case "bash":
      return <Terminal size={13} />;
    case "edit":
      return <FilePen size={13} />;
    case "external_directory":
      return <FolderOpen size={13} />;
    default:
      return <KeyRound size={13} />;
  }
}

/**
 * Mirror of the `questions` computed property: use item.questions when
 * present, else synthesize a single question from item.options.
 */
function questionsFor(item: FeedItem): FeedQuestion[] {
  if (item.questions && item.questions.length > 0) {
    return item.questions;
  }
  const options = item.options ?? [];
  if (options.length === 0) return [];
  return [
    {
      id: item.requestID,
      header: null,
      question: feedItemSummary(item),
      multiSelect: false,
      options: options.map((label, index) => ({ id: `option-${index}`, label })),
    },
  ];
}

// --- content sections ---------------------------------------------------------

/** Mirror of detailText: summary line + monospaced command box. */
function DetailText({ item }: { item: FeedItem }) {
  const summary = feedItemSummary(item);
  const command = trimmed(item.command);
  const showSummary = summary.length > 0 && summary !== feedItemDisplayTitle(item);
  const showCommand = command !== null && command !== summary;
  if (!showSummary && !showCommand) return null;
  return (
    <>
      {showSummary && <div className="oc-detail-text">{summary}</div>}
      {showCommand && <div className="oc-command-box">{command}</div>}
    </>
  );
}

/** Mirror of permissionContent. */
function PermissionContent({
  item,
  onReply,
}: {
  item: FeedItem;
  onReply: FeedInteractionCardProps["onReply"];
}) {
  const patterns = item.patterns ?? [];
  const permissionType = trimmed(item.permissionType);
  return (
    <div className="oc-section">
      <DetailText item={item} />
      {patterns.length > 0 ? (
        <div className="oc-patterns-box">
          <div className="oc-scope-label">
            {permissionScopeSymbol(item)}
            <span>{permissionScopeLabel(item)}</span>
          </div>
          {patterns.map((pattern, index) => (
            <div key={`${pattern}-${index}`} className="oc-pattern-row">
              {pattern}
            </div>
          ))}
        </div>
      ) : (
        permissionType !== null && (
          <div className="oc-scope-standalone">
            <ShieldCheck size={15} aria-hidden />
            <span>{humanized(permissionType)}</span>
          </div>
        )
      )}
      <div className="oc-actions-row">
        <ActionButton
          title="Allow once"
          icon={<Check size={13} />}
          role="primary"
          fillsWidth={false}
          onClick={() => onReply("approve", "once", null)}
        />
        <ActionButton
          title="Always"
          icon={<ShieldCheck size={13} />}
          role="secondary"
          fillsWidth={false}
          onClick={() => onReply("approve", "always", null)}
        />
        <ActionButton
          title="Reject"
          icon={<X size={13} />}
          role="destructive"
          fillsWidth={false}
          onClick={() => onReply("deny", "deny", null)}
        />
      </div>
    </div>
  );
}

interface QuestionWizardState {
  questions: FeedQuestion[];
  questionIndex: number;
  isReviewingAnswers: boolean;
  answers: Record<string, string>;
  setQuestionIndex: Dispatch<SetStateAction<number>>;
  setAnswers: Dispatch<SetStateAction<Record<string, string>>>;
  onReview: () => void;
  onReviewBack: () => void;
  everyQuestionAnswered: boolean;
}

/** Mirror of questionAnswerForm(_:). */
function QuestionAnswerForm({
  question,
  state,
}: {
  question: FeedQuestion;
  state: QuestionWizardState;
}) {
  const stored = state.answers[question.id] ?? "";
  const hasAnswer = stored.trim().length > 0;
  const isSelectedOption = question.options.some((option) => option.label === stored);
  const customValue = isSelectedOption ? "" : stored;

  return (
    <div className="oc-answer-form">
      <div className="oc-choices">
        {question.options.map((option) => (
          <ChoiceRow
            key={option.id}
            option={option}
            isSelected={option.label === stored}
            onSelect={() =>
              state.setAnswers((previous) => ({ ...previous, [question.id]: option.label }))
            }
          />
        ))}
      </div>
      <input
        className="oc-text-field"
        type="text"
        placeholder="Or type a custom answer"
        value={customValue}
        onChange={(event) =>
          state.setAnswers((previous) => ({ ...previous, [question.id]: event.target.value }))
        }
        aria-label="Custom answer"
      />
      <div className="oc-actions-row">
        {state.questionIndex > 0 && (
          <ActionButton
            title="Back"
            icon={<ChevronLeft size={13} />}
            role="neutral"
            fillsWidth={false}
            onClick={() => state.setQuestionIndex((index) => index - 1)}
          />
        )}
        {state.questionIndex < state.questions.length - 1 ? (
          <ActionButton
            title="Next"
            icon={<ChevronRight size={13} />}
            role="primary"
            fillsWidth={false}
            disabled={!hasAnswer}
            onClick={() => state.setQuestionIndex((index) => index + 1)}
          />
        ) : (
          <ActionButton
            title="Review answers"
            icon={<ListChecks size={13} />}
            role="primary"
            fillsWidth={false}
            disabled={!state.everyQuestionAnswered}
            onClick={state.onReview}
          />
        )}
      </div>
    </div>
  );
}

/** Mirror of questionContent (wizard, review, and free-text paths). */
function QuestionContent({
  item,
  state,
  onReply,
}: {
  item: FeedItem;
  state: QuestionWizardState;
  onReply: FeedInteractionCardProps["onReply"];
}) {
  if (state.isReviewingAnswers) {
    return (
      <div className="oc-section">
        <div className="oc-review-intro">Confirm these choices before OpenCode continues.</div>
        <div className="oc-review-rows">
          {state.questions.map((question) => {
            const header = trimmed(question.header);
            return (
              <div key={question.id} className="oc-review-row">
                <div className="oc-review-header">{header ?? question.question}</div>
                {header !== null && <div className="oc-review-question">{question.question}</div>}
                <div className="oc-review-answer">
                  <CircleCheck size={14} aria-hidden />
                  <span>{state.answers[question.id] ?? ""}</span>
                </div>
              </div>
            );
          })}
        </div>
        <div className="oc-actions-row">
          <ActionButton
            title="Back"
            icon={<ChevronLeft size={13} />}
            role="neutral"
            onClick={state.onReviewBack}
          />
          <ActionButton
            title="Submit"
            icon={<Send size={13} />}
            role="primary"
            onClick={() =>
              onReply(
                "answer",
                null,
                state.questions
                  .map((question) => (state.answers[question.id] ?? "").trim())
                  .filter((answer) => answer.length > 0),
              )
            }
          />
        </div>
      </div>
    );
  }

  const currentQuestion = state.questions[state.questionIndex];
  if (!currentQuestion) {
    // No questions (and no options): free-text answer path.
    const answer = (state.answers[item.requestID] ?? "").trim();
    return (
      <div className="oc-section">
        <DetailText item={item} />
        <input
          className="oc-text-field"
          type="text"
          placeholder="Type your answer"
          value={state.answers[item.requestID] ?? ""}
          onChange={(event) =>
            state.setAnswers((previous) => ({ ...previous, [item.requestID]: event.target.value }))
          }
          aria-label="Answer to OpenCode"
        />
        <div className="oc-actions-row oc-actions-trailing">
          <ActionButton
            title="Send answer"
            icon={<Send size={13} />}
            role="primary"
            fillsWidth={false}
            disabled={answer.length === 0}
            onClick={() => onReply("answer", null, answer.length > 0 ? [answer] : null)}
          />
        </div>
      </div>
    );
  }

  return (
    <div className="oc-section">
      {state.questions.length > 1 && (
        <div className="oc-question-counter">
          Question {state.questionIndex + 1} of {state.questions.length}
        </div>
      )}
      {trimmed(currentQuestion.header) !== null && (
        <div className="oc-question-header">{currentQuestion.header!.trim()}</div>
      )}
      <div className="oc-question-text">{currentQuestion.question}</div>
      <QuestionAnswerForm question={currentQuestion} state={state} />
    </div>
  );
}

/** Mirror of planContent. */
function PlanContent({ item, onReply }: { item: FeedItem; onReply: FeedInteractionCardProps["onReply"] }) {
  return (
    <div className="oc-section">
      <DetailText item={item} />
      <div className="oc-actions-row">
        <ActionButton
          title="Approve plan"
          icon={<Check size={13} />}
          role="primary"
          onClick={() => onReply("approve", "autoAccept", null)}
        />
        <ActionButton
          title="Keep manual"
          icon={<Hand size={13} />}
          role="secondary"
          onClick={() => onReply("manual", "manual", null)}
        />
        <ActionButton
          title="Reject"
          icon={<X size={13} />}
          role="destructive"
          onClick={() => onReply("deny", "deny", null)}
        />
      </div>
    </div>
  );
}

/** Mirror of genericContent + terminalNavigation(axis: .vertical). */
function GenericContent({ item, onSendKey }: { item: FeedItem; onSendKey: (key: string) => void }) {
  return (
    <div className="oc-section">
      <DetailText item={item} />
      <div className="oc-actions-row">
        <ActionButton
          title="Previous"
          icon={<ArrowUp size={13} />}
          role="neutral"
          onClick={() => onSendKey("up")}
        />
        <ActionButton
          title="Next"
          icon={<ArrowDown size={13} />}
          role="neutral"
          onClick={() => onSendKey("down")}
        />
        <ActionButton
          title="Confirm"
          icon={<CornerDownLeft size={13} />}
          role="primary"
          onClick={() => onSendKey("enter")}
        />
        <ActionButton
          title="Dismiss"
          icon={<X size={13} />}
          role="destructive"
          onClick={() => onSendKey("escape")}
        />
      </div>
    </div>
  );
}

// --- card ---------------------------------------------------------------------

export function FeedInteractionCard({ item, isSubmitting, onReply, onSendKey }: FeedInteractionCardProps) {
  const [questionIndex, setQuestionIndex] = useState(0);
  const [answers, setAnswers] = useState<Record<string, string>>({});
  const [isReviewingAnswers, setIsReviewingAnswers] = useState(false);

  // Mirror iOS .onChange(of: item.requestID) — reset wizard state per request.
  useEffect(() => {
    setQuestionIndex(0);
    setAnswers({});
    setIsReviewingAnswers(false);
  }, [item.requestID]);

  const questions = questionsFor(item);

  const wizardState: QuestionWizardState = {
    questions,
    questionIndex,
    isReviewingAnswers,
    answers,
    setQuestionIndex,
    setAnswers,
    everyQuestionAnswered: questions.every((question) => (answers[question.id] ?? "").trim().length > 0),
    onReview: () => setIsReviewingAnswers(true),
    onReviewBack: () => {
      setIsReviewingAnswers(false);
      setQuestionIndex(Math.max(questions.length - 1, 0));
    },
  };

  const cardTitle =
    item.kind === "permission"
      ? "Permission required"
      : item.kind === "question"
        ? isReviewingAnswers
          ? "Review answers"
          : "OpenCode question"
        : feedItemDisplayTitle(item);

  const headerIcon =
    item.kind === "permission" ? (
      <Hand size={16} />
    ) : item.kind === "question" ? (
      isReviewingAnswers ? (
        <CircleCheck size={16} />
      ) : (
        <MessageCircleQuestion size={16} />
      )
    ) : item.kind === "plan" ? (
      <FileText size={16} />
    ) : (
      <MessageCircleWarning size={16} />
    );

  const rawAgent = (item.agent ?? "").trim();
  const agent = rawAgent.toLowerCase() === "opencode" ? "OpenCode" : rawAgent || "OpenCode";
  const sourceLabel = `${agent} · ${isReviewingAnswers ? "Ready to submit" : "Awaiting response"}`;

  return (
    <div className={`oc-card oc-feed-card${isSubmitting ? " oc-card-submitting" : ""}`}>
      <InteractionHeader title={cardTitle} subtitle={sourceLabel} icon={headerIcon} isBusy={isSubmitting} />
      {item.kind === "permission" ? (
        <PermissionContent item={item} onReply={onReply} />
      ) : item.kind === "question" ? (
        <QuestionContent item={item} state={wizardState} onReply={onReply} />
      ) : item.kind === "plan" ? (
        <PlanContent item={item} onReply={onReply} />
      ) : (
        <GenericContent item={item} onSendKey={onSendKey} />
      )}
    </div>
  );
}
