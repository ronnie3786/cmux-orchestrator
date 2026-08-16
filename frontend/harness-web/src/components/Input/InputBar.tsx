import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
  type ReactNode,
} from "react";
import { ChevronUp, Send } from "lucide-react";
import { getSkills, sendTextOrKey } from "../../api/endpoints";
import type { HarnessKey, ProjectSkill } from "../../api/types";
import {
  computeSkillAutocompleteContext,
  filterSkillSuggestions,
  replaceSkillToken,
  type SkillAutocompleteContext,
} from "../../lib/skillAutocomplete";
import { HARNESS_KEY_LABELS, HARNESS_KEY_ROWS } from "../../lib/harnessKeys";
import { useConnectionStore } from "../../store/connectionStore";
import { useDraftStore } from "../../store/draftStore";
import { SkillAutocomplete } from "./SkillAutocomplete";

/**
 * Full input bar (iOS DetailInputBar.swift parity, Phase 4a — no attachments).
 *
 * - Multiline auto-growing textarea, 1–6 rows (iOS `lineLimit(1...6)`), scrolls
 *   beyond 6 rows. Bound to the per-workspace draft (draftStore — the same
 *   plumbing the Git tab's append-block + focus-request uses).
 * - Send semantics (kept from MinimalInputRow, which this replaces): a
 *   non-empty draft is sent as `text + "\n"` (iOS sendTextEffect parity),
 *   Enter in the field sends the draft, and Enter on an empty draft sends the
 *   literal enter key.
 * - Expandable action row: collapsed = row 1 quick keys (up/down/tab/enter),
 *   expanded adds row 2 (left/right/escape/backspace) — the exact iOS
 *   `HarnessKey.inputRows` split. The expanded attachment/file/Jira action
 *   buttons (paperclip, mic, @, ticket) land in Phase 4b/5 — the slot is
 *   marked below.
 * - Focus: focuses + marks handled when draftStore raises a focus request
 *   (Git tab inserts); focusing the field collapses the action row (iOS
 *   `onChange(of: isInputFocused)` parity). No auto-focus on selection — iOS
 *   does not focus the field on session select.
 *
 * Phase 4b slots (attachments + voice):
 * - `traySlot` renders the AttachmentTray chips above the main row (iOS puts
 *   the tray above the action row);
 * - `canSend` / `isUploading` mirror iOS `canSend` — the upload-in-flight
 *   gate and the "has uploaded attachment" disjunct slot in there.
 */

export interface InputBarProps {
  /** cmux index of the selected session; null disables the bar. */
  index: number | null;
  /** Surface id for multi-pane sessions (iOS sends workspace.surfaceId). */
  surfaceId?: string | null;
  /**
   * Phase 4b slot: attachment tray (chips with uploading/uploaded/error
   * states) + any in-flight upload indicator. Rendered above the main row,
   * matching the iOS DetailInputBar tray position.
   */
  traySlot?: ReactNode;
}

// --- skills loading (lazy per index, cached across remounts) ----------------
//
// iOS loads skills through the shared store (also used by the Skills tab); the
// web Skills tab lands in Phase 5, so the autocomplete keeps its own
// module-level cache keyed by cmux index. A failed load evicts the cache entry
// so the next trigger retries.

const skillsCache = new Map<number, Promise<ProjectSkill[]>>();

function loadSkillsForIndex(index: number): Promise<ProjectSkill[]> {
  let pending = skillsCache.get(index);
  if (!pending) {
    pending = getSkills(index)
      .then((response) => {
        return (
          response.skills ?? [...(response.projectSkills ?? []), ...(response.userSkills ?? [])]
        );
      })
      .catch((error) => {
        skillsCache.delete(index);
        throw error;
      });
    skillsCache.set(index, pending);
  }
  return pending;
}

// Auto-grow geometry — must match .input-bar-textarea / .input-bar-textarea-mirror
// in global.css (line-height 20px, vertical padding 12px, font-size 13px).
const TEXTAREA_LINE_HEIGHT_PX = 20;
const TEXTAREA_VERTICAL_PADDING_PX = 24;
const MAX_ROWS = 6;

export function InputBar({ index, surfaceId = null, traySlot }: InputBarProps) {
  const draft = useDraftStore((state) => state.activeDraft);
  const setDraft = useDraftStore((state) => state.setDraft);
  const focusRequest = useDraftStore((state) => state.focusRequest);

  const [expanded, setExpanded] = useState(false);
  const [busy, setBusy] = useState(false);
  /** Caret offset in the draft (textarea selectionStart). */
  const [caret, setCaret] = useState(0);
  /** Signature of the token the user dismissed (iOS dismissedSkillAutocompleteSignature). */
  const [dismissedSignature, setDismissedSignature] = useState<string | null>(null);
  /** Keyboard-highlighted suggestion row. */
  const [highlight, setHighlight] = useState(0);
  /** Loaded skills for the current index (null = not loaded yet). */
  const [skills, setSkills] = useState<ProjectSkill[] | null>(null);

  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const mirrorRef = useRef<HTMLDivElement>(null);
  /** Caret to apply after the next controlled value commit (skill select). */
  const pendingCaretRef = useRef<number | null>(null);

  const disabled = index === null || busy;

  // iOS `detailInputFocusHandled` (moved from MinimalInputRow): the Git tab
  // (diff-line comments, PR threads) bumps the request; focus at the end of
  // the draft and mark it handled. Runs on mount too, so a request raised
  // while the Git tab was showing lands when this bar mounts on the Terminal
  // tab.
  useEffect(() => {
    if (focusRequest === 0) return;
    const el = textareaRef.current;
    if (el) {
      el.focus();
      const end = el.value.length;
      el.setSelectionRange(end, end);
    }
    useDraftStore.getState().markFocusHandled(focusRequest);
  }, [focusRequest]);

  // Auto-grow: mirror the textarea content in a hidden same-width div and
  // count wrapped lines (iOS lineLimit(1...6) grows on wrapped lines, not just
  // logical newlines). Beyond MAX_ROWS the textarea scrolls.
  useLayoutEffect(() => {
    const textarea = textareaRef.current;
    const mirror = mirrorRef.current;
    if (!textarea || !mirror) return;
    const styles = window.getComputedStyle(textarea);
    const horizontalPadding = parseFloat(styles.paddingLeft) + parseFloat(styles.paddingRight);
    mirror.style.width = `${Math.max(0, textarea.clientWidth - horizontalPadding)}px`;
    mirror.textContent = draft.length > 0 ? draft : "\u00A0";
    const lineCount = Math.max(1, Math.round(mirror.offsetHeight / TEXTAREA_LINE_HEIGHT_PX));
    textarea.style.height = `${
      Math.min(lineCount, MAX_ROWS) * TEXTAREA_LINE_HEIGHT_PX + TEXTAREA_VERTICAL_PADDING_PX
    }px`;
  }, [draft]);

  // Apply a pending caret (skill token replacement) after the value commit.
  useLayoutEffect(() => {
    const el = textareaRef.current;
    const pending = pendingCaretRef.current;
    if (el && pending !== null) {
      el.setSelectionRange(pending, pending);
      pendingCaretRef.current = null;
    }
  }, [draft]);

  // --- skill autocomplete (iOS DetailInputBar + SkillAutocompleteViews) ------

  const context: SkillAutocompleteContext | null = useMemo(
    () => computeSkillAutocompleteContext(draft, caret),
    [draft, caret],
  );
  const contextSignature = context?.signature ?? null;

  // Lazy-load skills on first trigger (iOS loadSkillsIfNeededForAutocomplete).
  useEffect(() => {
    if (context === null || index === null || skills !== null) return;
    let cancelled = false;
    loadSkillsForIndex(index)
      .then((list) => {
        if (!cancelled) setSkills(list);
      })
      .catch(() => {
        // Silent — the panel just stays hidden (iOS shows no error here either).
        if (!cancelled) setSkills([]);
      });
    return () => {
      cancelled = true;
    };
  }, [context, index, skills]);

  const suggestions = useMemo(() => {
    if (skills === null || context === null) return [];
    return filterSkillSuggestions(skills, context.query);
  }, [skills, context]);

  // iOS: the panel shows while a context exists, the current token wasn't
  // dismissed, and there is at least one suggestion.
  const panelOpen =
    context !== null && dismissedSignature !== context.signature && suggestions.length > 0;

  // Reset the highlight whenever the token identity changes.
  useEffect(() => {
    setHighlight(0);
  }, [contextSignature]);

  const clampedHighlight = suggestions.length > 0 ? Math.min(highlight, suggestions.length - 1) : 0;

  // --- send (same code path MinimalInputRow used) ----------------------------

  const send = useCallback(
    async (payload: { text?: string; key?: HarnessKey }) => {
      if (index === null) return;
      setBusy(true);
      try {
        // iOS sendTextEffect parity: input-bar text executes in the terminal
        // (iOS sends `message + "\n"`). Quick keys are unaffected.
        await sendTextOrKey({
          index,
          ...(surfaceId ? { surfaceId } : {}),
          ...payload,
          ...(payload.text ? { text: payload.text + "\n" } : {}),
        });
        useConnectionStore.getState().clearError();
        if (payload.text) {
          // iOS sends the draft then clears it (persistDetailDraft removes the
          // stored entry for an empty draft).
          useDraftStore.getState().clearDraft();
          setCaret(0);
          pendingCaretRef.current = 0;
        }
        textareaRef.current?.focus();
      } catch (err) {
        // Surface via the sidebar error banner (same as the rest of the detail
        // view's actions).
        useConnectionStore.setState({
          errorMessage: err instanceof Error ? err.message : "Send failed",
        });
      } finally {
        setBusy(false);
      }
    },
    [index, surfaceId],
  );

  const sendKey = useCallback(
    (key: HarnessKey) => {
      void send({ key });
    },
    [send],
  );

  // iOS `replaceSkillToken`: replace the token with prefix + name, caret right
  // after the replacement, re-focus the field. (No trailing space — iOS parity;
  // the panel stays open since the replaced token still matches, exactly like
  // on iOS. Selecting again is a no-op; typing continues to narrow.)
  const selectSkill = useCallback(
    (skill: ProjectSkill) => {
      if (context === null) return;
      const result = replaceSkillToken(draft, context, skill.name);
      pendingCaretRef.current = result.cursor;
      setDismissedSignature(null);
      setCaret(result.cursor);
      setDraft(result.draft);
      textareaRef.current?.focus();
    },
    [context, draft, setDraft],
  );

  const handleKeyDown = (event: ReactKeyboardEvent<HTMLTextAreaElement>) => {
    const activeContext = computeSkillAutocompleteContext(
      draft,
      event.currentTarget.selectionStart ?? draft.length,
    );
    if (activeContext !== null && panelOpen) {
      if (event.key === "ArrowDown") {
        event.preventDefault();
        setHighlight((current) => Math.min(current + 1, suggestions.length - 1));
        return;
      }
      if (event.key === "ArrowUp") {
        event.preventDefault();
        setHighlight((current) => Math.max(current - 1, 0));
        return;
      }
      if (event.key === "Enter") {
        event.preventDefault();
        const skill = suggestions[clampedHighlight];
        if (skill) selectSkill(skill);
        return;
      }
      if (event.key === "Escape") {
        // Cancel the panel for this token (iOS cancelAction); keep the focus.
        event.preventDefault();
        setDismissedSignature(activeContext.signature);
        return;
      }
    }
    if (event.key === "Enter") {
      event.preventDefault();
      if (draft.trim().length > 0) {
        void send({ text: draft });
      } else {
        sendKey("enter");
      }
      return;
    }
    if (event.key === "Escape") {
      // No field-level Esc in iOS; web idiom: Esc dismisses the field focus
      // (the dedicated Esc quick key still sends escape to the terminal).
      event.preventDefault();
      event.currentTarget.blur();
    }
  };

  // --- send button rules (iOS `canSend`, 4a: draft-only) ----------------------
  //
  // Phase 4b: `const isUploading = attachments.some(a => a.status === "uploading")`
  //          `const hasUploaded = attachments.some(a => a.status === "uploaded" && a.uploadedPath)`
  //          canSend = !isUploading && (hasMessage || hasUploaded)
  const hasMessage = draft.trim().length > 0;
  const canSend = hasMessage;

  return (
    <div className="input-bar">
      {panelOpen && context !== null ? (
        <SkillAutocomplete
          suggestions={suggestions}
          invocationPrefix={context.invocationPrefix}
          highlight={clampedHighlight}
          onSelect={(skill) => selectSkill(skill)}
          onCancel={() => setDismissedSignature(context.signature)}
        />
      ) : null}

      {/* Phase 4b: <AttachmentTray/> lands here (above the main row, iOS parity). */}
      {traySlot ? <div className="input-bar-tray">{traySlot}</div> : null}

      {/* Phase 4b/5 slot: the iOS expanded action row (paperclip attach,
          mic voice note, @ file search, ticket Jira) renders here between the
          tray and the main row once 4b lands AttachmentTray. Deliberately not
          rendered in 4a — the row would be an empty gap. */}

      <div className="input-bar-main">
        <button
          type="button"
          className={`input-bar-chevron${expanded ? " input-bar-chevron-expanded" : ""}`}
          title={expanded ? "Hide quick keys row 2" : "Show quick keys row 2"}
          aria-label={expanded ? "Hide input actions" : "Show input actions"}
          aria-expanded={expanded}
          disabled={index === null}
          onClick={() => setExpanded((value) => !value)}
        >
          <ChevronUp size={16} aria-hidden="true" />
        </button>

        <div className="input-bar-field-wrap">
          <textarea
            ref={textareaRef}
            className="input-bar-textarea"
            placeholder={index === null ? "Select a session" : "Type a message or instruction…"}
            value={draft}
            disabled={disabled}
            rows={1}
            spellCheck
            autoCapitalize="sentences"
            autoCorrect="on"
            aria-label="Send text to the session"
            onChange={(event) => {
              // iOS onChange(of: detailDraft): any edit clears a dismissal.
              setDismissedSignature(null);
              setCaret(event.target.selectionStart ?? 0);
              setDraft(event.target.value);
            }}
            onSelect={(event) => setCaret(event.currentTarget.selectionStart ?? 0)}
            onFocus={() => {
              // iOS onChange(of: isInputFocused): focusing collapses the
              // action row.
              setExpanded(false);
            }}
            onKeyDown={handleKeyDown}
          />
          {/* Hidden measurement mirror for the auto-grow (styled in CSS). */}
          <div ref={mirrorRef} className="input-bar-textarea-mirror" aria-hidden="true" />
        </div>

        <button
          type="button"
          className="input-bar-send"
          title="Send"
          aria-label="Send message"
          disabled={disabled || !canSend}
          onClick={() => void send({ text: draft })}
        >
          <Send size={16} aria-hidden="true" />
        </button>
      </div>

      <div className="input-bar-key-rows">
        {/* Row 1 (iOS): always visible. */}
        <div className="input-bar-key-row">
          {HARNESS_KEY_ROWS[0].map((key) => (
            <button
              key={key}
              type="button"
              className="input-bar-key"
              title={`Send ${HARNESS_KEY_LABELS[key]} key`}
              disabled={disabled}
              onClick={() => sendKey(key)}
            >
              {HARNESS_KEY_LABELS[key]}
            </button>
          ))}
        </div>
        {/* Row 2 (iOS): only when the action row is expanded. */}
        {expanded ? (
          <div className="input-bar-key-row">
            {HARNESS_KEY_ROWS[1].map((key) => (
              <button
                key={key}
                type="button"
                className="input-bar-key"
                title={`Send ${HARNESS_KEY_LABELS[key]} key`}
                disabled={disabled}
                onClick={() => sendKey(key)}
              >
                {HARNESS_KEY_LABELS[key]}
              </button>
            ))}
          </div>
        ) : null}
      </div>
    </div>
  );
}
