/**
 * AttachmentTray — web port of cmux-harness-ios Views/Input/AttachmentViews.
 *
 * iOS: horizontal ScrollView of chips (height 52, corner radius 14), each
 * chip = SF Symbol icon (20×20) + filename (middle ellipsis, max 170) +
 * status caption (Uploading / Added / error) + spinner or retry + remove.
 * Web parity: same chip anatomy; image attachments get a 32×32 thumbnail
 * (object URL, revoked when the chip unmounts) in place of the icon.
 */

import { useEffect, useState } from "react";
import {
  Archive,
  AudioWaveform,
  Check,
  File as FileIcon,
  FileText,
  Image as ImageIcon,
  Loader2,
  RotateCw,
  X,
} from "lucide-react";
import type { Attachment } from "../../store/attachmentsStore";

const IMAGE_EXTENSIONS = ["png", "jpg", "jpeg", "heic", "gif", "webp"];
const AUDIO_EXTENSIONS = ["m4a", "mp3", "wav", "aac", "caf", "webm", "ogg"];
const PDF_EXTENSIONS = ["pdf"];
const ARCHIVE_EXTENSIONS = ["zip", "gz", "tar", "7z"];
const MAX_NAME_CHARS = 24;

function fileExtension(name: string): string {
  const dot = name.lastIndexOf(".");
  return dot >= 0 ? name.slice(dot + 1).toLowerCase() : "";
}

function isImageAttachment(attachment: Attachment): boolean {
  return (
    attachment.mime.startsWith("image/") ||
    IMAGE_EXTENSIONS.includes(fileExtension(attachment.name))
  );
}

/** iOS truncationMode(.middle): `abcdef…wxyz` for long names. */
function middleTruncate(name: string): string {
  if (name.length <= MAX_NAME_CHARS) return name;
  const head = Math.ceil(MAX_NAME_CHARS / 2);
  const tail = Math.floor(MAX_NAME_CHARS / 2) - 1; // 1 char for the ellipsis
  return `${name.slice(0, head)}…${name.slice(name.length - tail)}`;
}

function fileIcon(attachment: Attachment, size = 20) {
  const extension = fileExtension(attachment.name);
  if (isImageAttachment(attachment)) return <ImageIcon size={size} />;
  if (AUDIO_EXTENSIONS.includes(extension) || attachment.mime.startsWith("audio/"))
    return <AudioWaveform size={size} />;
  if (PDF_EXTENSIONS.includes(extension) || attachment.mime === "application/pdf")
    return <FileText size={size} />;
  if (ARCHIVE_EXTENSIONS.includes(extension)) return <Archive size={size} />;
  return <FileIcon size={size} />;
}

/**
 * Object URL for image thumbnails, revoked when the chip unmounts or the
 * source file changes (the tray requirement — no leaked blob URLs).
 */
function useImageThumbnail(attachment: Attachment): string | null {
  const [url, setUrl] = useState<string | null>(null);
  const showThumbnail = attachment.state !== "uploading" && isImageAttachment(attachment);

  useEffect(() => {
    if (!showThumbnail) return;
    const objectUrl = URL.createObjectURL(attachment.file);
    setUrl(objectUrl);
    return () => {
      URL.revokeObjectURL(objectUrl);
      setUrl(null);
    };
  }, [attachment.file, attachment.id, showThumbnail]);

  return showThumbnail ? url : null;
}

interface AttachmentChipProps {
  attachment: Attachment;
  onRemove: () => void;
  onRetry: () => void;
}

function AttachmentChip({ attachment, onRemove, onRetry }: AttachmentChipProps) {
  const thumbnailUrl = useImageThumbnail(attachment);
  const stateClass =
    attachment.state === "uploading"
      ? "attachment-chip-uploading"
      : attachment.state === "added"
        ? "attachment-chip-added"
        : "attachment-chip-error";

  const statusText =
    attachment.state === "uploading"
      ? "Uploading"
      : attachment.state === "added"
        ? "Added"
        : (attachment.error ?? "Failed");

  return (
    <div className={`attachment-chip ${stateClass}`} role="listitem">
      {thumbnailUrl ? (
        <img className="attachment-chip-thumb" src={thumbnailUrl} alt="" />
      ) : (
        <span className="attachment-chip-icon" aria-hidden="true">
          {fileIcon(attachment)}
        </span>
      )}
      <span className="attachment-chip-text">
        <span className="attachment-chip-name" title={attachment.name}>
          {middleTruncate(attachment.name)}
        </span>
        <span className="attachment-chip-status">{statusText}</span>
      </span>
      {attachment.state === "uploading" ? (
        <Loader2 size={14} className="attachment-chip-spinner" aria-label="Uploading" />
      ) : attachment.state === "error" ? (
        <button
          type="button"
          className="attachment-chip-action"
          title="Retry upload"
          aria-label={`Retry uploading ${attachment.name}`}
          onClick={onRetry}
        >
          <RotateCw size={14} />
        </button>
      ) : (
        <Check size={14} className="attachment-chip-check" aria-hidden="true" />
      )}
      <button
        type="button"
        className="attachment-chip-action"
        title="Remove"
        aria-label={`Remove ${attachment.name}`}
        onClick={onRemove}
      >
        <X size={14} />
      </button>
    </div>
  );
}

interface AttachmentTrayProps {
  attachments: Attachment[];
  onRemove: (id: string) => void;
  onRetry: (id: string) => void;
}

export function AttachmentTray({ attachments, onRemove, onRetry }: AttachmentTrayProps) {
  if (attachments.length === 0) return null;
  return (
    <div className="attachment-tray" role="list" aria-label="Attachments">
      {attachments.map((attachment) => (
        <AttachmentChip
          key={attachment.id}
          attachment={attachment}
          onRemove={() => onRemove(attachment.id)}
          onRetry={() => onRetry(attachment.id)}
        />
      ))}
    </div>
  );
}
