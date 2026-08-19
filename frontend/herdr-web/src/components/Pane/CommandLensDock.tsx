/**
 * Command Lens dock (P9-run-B) — owns the aux-bar actions of
 * PromptComposerView for the selected pane: "@ file" opens the workspace
 * FileSearchModal, "jira" the JiraModal, "attach" a native file input.
 * Picks land in the composer (refocus included): file rows insert a
 * backticked path token (doc 01 §3: the file-search sheet "tap inserts
 * `path`"); Jira tickets insert the byte-exact 3-line block (doc 01 §6);
 * attachment files go through the attachmentsStore and render as chips
 * above the composer (Phase-1 AttachmentTray pattern, doc 01 §6 states:
 * "uploading" / "attached" / "upload failed").
 */
import { forwardRef, useImperativeHandle, useRef, useState } from "react";
import { Check, File as FileIcon, Loader2, X } from "lucide-react";
import type { ProjectSkill } from "../../api/skills";
import type { JiraTicket } from "../../api/tools";
import { skillInsertToken, type SkillInsertStyle } from "../../lib/skillInsert";
import { formatJiraTicketInsert } from "../../lib/promptInsert";
import { useAttachmentsStore, type Attachment } from "../../store/attachmentsStore";
import { FileSearchModal } from "../Tools/FileSearchModal";
import { JiraModal } from "../Tools/JiraModal";
import { PromptComposerView, type PromptComposerHandle } from "./PromptComposerView";
import type { AuxActionName } from "./ComposerAuxBar";
import type { Pane } from "../../types/herdr";

/** Imperative insert entry point for the Skills view (P11-run-B). */
export interface CommandLensDockHandle {
  /** Appends the byte-exact skill token (iOS SkillInsertionStyle) + refocuses. */
  insertSkill: (skill: Pick<ProjectSkill, "name" | "skill_file_path">, style: SkillInsertStyle) => void;
}

export const CommandLensDock = forwardRef<CommandLensDockHandle, { pane: Pane }>(
  function CommandLensDock({ pane }, ref) {
    const workspaceId = pane.workspace_id;
    const [modal, setModal] = useState<null | "file" | "jira">(null);
    const fileInputRef = useRef<HTMLInputElement>(null);
    const composerRef = useRef<PromptComposerHandle>(null);
    const attachments = useAttachmentsStore((state) => state.byWorkspace[workspaceId]);

    useImperativeHandle(ref, () => ({
      insertSkill: (skill, style) => {
        composerRef.current?.insert(skillInsertToken(skill, style), "token");
      },
    }), []);

    const onAction = (name: AuxActionName): void => {
      if (name === "attach") {
        fileInputRef.current?.click();
        return;
      }
      setModal(name === "@ file" ? "file" : "jira");
    };

    const insertFilePath = (path: string): void => {
      composerRef.current?.insert(`\`${path}\``, "token");
      setModal(null);
    };

    const insertJiraTicket = (ticket: JiraTicket): void => {
      composerRef.current?.insert(formatJiraTicketInsert(ticket), "block");
      setModal(null);
    };

    const onFilesPicked = (event: React.ChangeEvent<HTMLInputElement>): void => {
      const files = event.target.files;
      if (files !== null) {
        for (const file of Array.from(files)) {
          useAttachmentsStore.getState().uploadFile(workspaceId, file);
        }
      }
      event.target.value = "";
    };

    return (
      <div className="hz-pane-dock">
        <input
          ref={fileInputRef}
          type="file"
          multiple
          style={{ display: "none" }}
          aria-hidden
          tabIndex={-1}
          onChange={onFilesPicked}
        />
        {attachments !== undefined && attachments.length > 0 ? (
          <AttachmentChipRow
            workspaceId={workspaceId}
            attachments={attachments}
          />
        ) : null}
        <PromptComposerView ref={composerRef} pane={pane} onAction={onAction} />
        {modal === "file" ? (
          <FileSearchModal
            workspaceId={workspaceId}
            onPick={insertFilePath}
            onClose={() => setModal(null)}
          />
        ) : null}
        {modal === "jira" ? (
          <JiraModal onPick={insertJiraTicket} onClose={() => setModal(null)} />
        ) : null}
      </div>
    );
  },
);

function chipClass(state: Attachment["state"]): string {
  switch (state) {
    case "uploading":
      return "attachment-chip-uploading";
    case "attached":
      return "attachment-chip-added";
    default:
      return "attachment-chip-error";
  }
}

function chipStatus(attachment: Attachment): string {
  if (attachment.state === "failed") return attachment.error ?? "upload failed";
  return attachment.state;
}

function AttachmentChipRow({
  workspaceId,
  attachments,
}: {
  workspaceId: string;
  attachments: Attachment[];
}) {
  const remove = (id: string): void => {
    useAttachmentsStore.getState().remove(workspaceId, id);
  };
  return (
    <div className="attachment-tray hz-pane-attachments" role="list" aria-label="Attachments">
      {attachments.map((attachment) => (
        <div
          key={attachment.id}
          className={`attachment-chip ${chipClass(attachment.state)}`}
          role="listitem"
        >
          <span className="attachment-chip-icon" aria-hidden="true">
            <FileIcon size={20} />
          </span>
          <span className="attachment-chip-text">
            <span className="attachment-chip-name" title={attachment.filename}>
              {attachment.filename}
            </span>
            <span className="attachment-chip-status">{chipStatus(attachment)}</span>
          </span>
          {attachment.state === "uploading" ? (
            <Loader2 size={14} className="attachment-chip-spinner" aria-label="Uploading" />
          ) : attachment.state === "attached" ? (
            <Check size={14} className="attachment-chip-check" aria-hidden="true" />
          ) : (
            <button
              type="button"
              className="attachment-chip-action"
              title="Remove"
              aria-label={`Remove ${attachment.filename}`}
              onClick={() => remove(attachment.id)}
            >
              <X size={14} />
            </button>
          )}
        </div>
      ))}
    </div>
  );
}
