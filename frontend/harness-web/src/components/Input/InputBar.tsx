import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ChangeEvent as ReactChangeEvent,
  type KeyboardEvent as ReactKeyboardEvent,
  type ReactNode,
} from "react";
import { ChevronUp, Folder, Image as ImageIcon, Mic, Paperclip, Send, Ticket } from "lucide-react";
import { getSkills, sendTextOrKey } from "../../api/endpoints";
import type { HarnessKey, ProjectSkill } from "../../api/types";
import {
  computeSkillAutocompleteContext,
  filterSkillSuggestions,
  replaceSkillToken,
  type SkillAutocompleteContext,
} from "../../lib/skillAutocomplete";
import { HARNESS_KEY_LABELS, HARNESS_KEY_ROWS } from "../../lib/harnessKeys";
import {
  activeAttachmentsOf,
  inFlightCount,
  useAttachmentsStore,
  uploadedPaths,
} from "../../store/attachmentsStore";
import { useConnectionStore } from "../../store/connectionStore";
import { useDraftStore } from "../../store/draftStore";
import { AttachmentTray } from "./AttachmentTray";
import { SkillAutocomplete } from "./SkillAutocomplete";
import { VoiceNoteSheet } from "./VoiceNoteSheet";

/**
 * Full input bar (iOS DetailInputBar.swift parity, Phase 4a/4b — quick keys,
 * skill autocomplete, attachments tray, voice notes).
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
 * - the AttachmentTray chips render above the main row (iOS puts the tray
 *   above the action row), fed by the attachmentsStore via `workspaceID`;
 * - `canSend` / `isUploading` mirror iOS `canSend` — the upload-in-flight
 *   gate plus the "has uploaded attachment" disjunct;
 * - the expanded action row carries the paperclip (Photos / Files menu over
 *   two hidden <input type=file multiple>) and the mic (VoiceNoteSheet);
 * - send joins uploaded server paths + the draft (iOS sendDetailDraft),
 *   clears both on success, and is gated while uploads are in flight.
 */

export interface InputBarProps {
  /** cmux index of the selected session; null disables the bar. */
  index: number | null;
  /** Surface id for multi-pane sessions (iOS sends workspace.surfaceId). */
  surfaceId?: string | null;
  /**
   * Stable workspace row id (workspaceGroups.workspaceID) — keys the draft
   * and attachment stores, exactly like the iOS workspace id.
   */
  workspaceID: string;
  /** Workspace UUID for the upload headers (X-Cmux-Workspace-UUID). */
  workspaceUUID?: string | null;
  /**
   * Extra content rendered in the tray area above the input row (the
   * AttachmentTray itself is rendered by the bar, keyed by `workspaceID`).
   */
  traySlot?: ReactNode;
  /**
   * Phase 5: open a tools modal from the expanded action row (iOS
   * `.fileSearchTapped` / `.jiraTicketsTapped`). Owned by the detail view so
   * the modal survives tab switches and stays available while the bar shows.
   */
  onOpenTools?: (tool: "fileSearch" | "jira") => void;
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

export function InputBar({
  index,
  surfaceId = null,
  workspaceID,
  workspaceUUID = null,
  traySlot,
  onOpenTools,
}: InputBarProps) {
  const draft = useDraftStore((state) => state.activeDraft);
  const setDraft = useDraftStore((state) => state.setDraft);
  const focusRequest = useDraftStore((state) => state.focusRequest);

  // Attachments follow the same workspace-row binding as the draft (iOS
  // terminalAttachments[workspaceID] is read/written by the same reducer).
  const attachments = useAttachmentsStore(activeAttachmentsOf);

  const [expanded, setExpanded] = useState(false);
  const [busy, setBusy] = useState(false);
  /** Paperclip menu open (iOS confirmationDialog: Photo Library vs Files). */
  const [attachMenuOpen, setAttachMenuOpen] = useState(false);
  /** Voice note sheet open (iOS shows the sheet over the detail view). */
  const [voiceSheetOpen, setVoiceSheetOpen] = useState(false);
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
  /** Hidden pickers: images-only (iOS Photos parity) vs any file. */
  const photoInputRef = useRef<HTMLInputElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
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
          // stored entry for an empty draft); sendDetailDraft also clears the
          // workspace's terminalAttachments.
          useDraftStore.getState().clearDraft();
          useAttachmentsStore.getState().clearActive();
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

  /**
   * iOS sendDetailDraft: wait for in-flight uploads, join the uploaded server
   * paths with the trimmed draft (space-separated), then send as text.
   */
  const sendDraft = useCallback(
    (text: string) => {
      if (index === null) return;
      const workspaceAttachments = useAttachmentsStore.getState().byWorkspace[workspaceID] ?? [];
      if (workspaceAttachments.some((attachment) => attachment.state === "uploading")) {
        useConnectionStore.setState({ errorMessage: "Wait for attachment uploads to finish" });
        return;
      }
      const paths = uploadedPaths(workspaceAttachments);
      const message = text.trim();
      if (message.length === 0 && paths.length === 0) return;
      void send({ text: [...paths, ...(message.length > 0 ? [message] : [])].join(" ") });
    },
    [index, workspaceID, send],
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
      // iOS send is enabled by a non-empty draft OR an uploaded attachment;
      // a truly empty bar with nothing uploaded sends the literal enter key.
      if (canSend) {
        sendDraft(draft);
      } else if (draft.trim().length === 0) {
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

  // --- send button rules (iOS `canSend`) ------------------------------------
  // Uploads gate the button; an uploaded attachment alone is enough to send
  // (the payload becomes the space-joined server paths).
  const isUploading = inFlightCount(attachments) > 0;
  const hasUploadedAttachment = uploadedPaths(attachments).length > 0;
  const hasMessage = draft.trim().length > 0;
  const canSend = !isUploading && (hasMessage || hasUploadedAttachment);

  // iOS paperclip menu: Photo Library (images) vs Files (any type).
  const openPicker = (kind: "photo" | "file") => {
    setAttachMenuOpen(false);
    (kind === "photo" ? photoInputRef.current : fileInputRef.current)?.click();
  };

  const handleFilesSelected = (event: ReactChangeEvent<HTMLInputElement>) => {
    const files = Array.from(event.target.files ?? []);
    event.target.value = ""; // allow re-selecting the same file
    if (files.length === 0 || index === null) return;
    useAttachmentsStore
      .getState()
      .addFiles(files, workspaceID, { index, uuid: workspaceUUID });
  };

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

      {/* Phase 4b: paperclip (Photos / Files) + mic (voice note sheet), shown
          with the expanded state exactly like the iOS action row. Phase 5:
          @ file-search + Jira ticket. */}
      {attachMenuOpen ? (
        <div className="attach-menu" role="menu" aria-label="Attachment source">
          <button
            type="button"
            role="menuitem"
            className="menu-item"
            onClick={() => openPicker("photo")}
          >
            <ImageIcon size={14} className="menu-item-icon" aria-hidden="true" />
            <span className="menu-item-label">Photos</span>
          </button>
          <button
            type="button"
            role="menuitem"
            className="menu-item"
            onClick={() => openPicker("file")}
          >
            <Folder size={14} className="menu-item-icon" aria-hidden="true" />
            <span className="menu-item-label">Files</span>
          </button>
        </div>
      ) : null}

      <AttachmentTray
        attachments={attachments}
        onRemove={(id) => useAttachmentsStore.getState().remove(id)}
        onRetry={(id) => useAttachmentsStore.getState().retry(id)}
      />
      {traySlot ? <div className="input-bar-tray">{traySlot}</div> : null}

      {expanded ? (
        <div className="input-bar-actions">
          <button
            type="button"
            className="input-action-button"
            title="Attach file"
            aria-label="Attach file"
            disabled={index === null}
            onClick={() => setAttachMenuOpen((value) => !value)}
          >
            <Paperclip size={16} aria-hidden="true" />
          </button>
          <button
            type="button"
            className="input-action-button"
            title="Record voice note"
            aria-label="Record voice note"
            disabled={index === null}
            onClick={() => setVoiceSheetOpen(true)}
          >
            <Mic size={16} aria-hidden="true" />
          </button>
          {/* Phase 5 (iOS action-row parity): @ file-search + Jira ticket. */}
          <button
            type="button"
            className="input-action-button input-action-button-at"
            title="Add file path"
            aria-label="Add file path"
            disabled={index === null}
            onClick={() => onOpenTools?.("fileSearch")}
          >
            @
          </button>
          <button
            type="button"
            className="input-action-button"
            title="Add Jira ticket"
            aria-label="Add Jira ticket"
            disabled={index === null}
            onClick={() => onOpenTools?.("jira")}
          >
            <Ticket size={16} aria-hidden="true" />
          </button>
        </div>
      ) : null}

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
          onClick={() => sendDraft(draft)}
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

      {/* Phase 4b pickers: images-only (iOS Photos parity) vs any file. */}
      <input
        ref={photoInputRef}
        type="file"
        accept="image/*"
        multiple
        className="input-file-hidden"
        tabIndex={-1}
        aria-hidden="true"
        onChange={handleFilesSelected}
      />
      <input
        ref={fileInputRef}
        type="file"
        multiple
        className="input-file-hidden"
        tabIndex={-1}
        aria-hidden="true"
        onChange={handleFilesSelected}
      />

      {attachMenuOpen ? (
        <div className="menu-backdrop" onClick={() => setAttachMenuOpen(false)} />
      ) : null}
      {voiceSheetOpen ? (
        <VoiceNoteSheet
          onSave={(file) => {
            if (index === null) return;
            useAttachmentsStore
              .getState()
              .addFiles([file], workspaceID, { index, uuid: workspaceUUID });
            setVoiceSheetOpen(false);
          }}
          onDismiss={() => setVoiceSheetOpen(false)}
        />
      ) : null}
    </div>
  );
}
