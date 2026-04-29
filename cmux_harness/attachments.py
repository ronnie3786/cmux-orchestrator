from __future__ import annotations

import os
import re
import time
import urllib.parse
import uuid
from datetime import datetime, timezone
from pathlib import Path

from . import storage


ATTACHMENTS_DIR = storage.LOG_DIR / "attachments"
MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024
RETENTION_SECONDS = 7 * 24 * 60 * 60


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _safe_component(value: str, fallback: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9._-]+", "-", str(value or "").strip())
    safe = re.sub(r"-+", "-", safe).strip(".-_")
    return safe or fallback


def workspace_attachment_key(workspace_uuid: str = "", workspace_index: str | int | None = None) -> str:
    uuid_value = _safe_component(workspace_uuid, "")
    if uuid_value:
        return uuid_value

    try:
        index_value = int(str(workspace_index or "").strip())
    except (TypeError, ValueError):
        index_value = 0
    return f"index-{index_value}"


def safe_attachment_filename(filename: str) -> str:
    raw = urllib.parse.unquote(str(filename or "").strip())
    raw_name = Path(raw).name or "attachment"
    stem, ext = os.path.splitext(raw_name)
    safe_stem = re.sub(r"[^A-Za-z0-9._-]+", "_", stem).strip("._-")
    safe_ext = re.sub(r"[^A-Za-z0-9.]+", "", ext)[:24]
    if not safe_stem:
        safe_stem = "attachment"
    safe_stem = safe_stem[:90].rstrip("._-") or "attachment"
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{timestamp}-{uuid.uuid4().hex[:8]}-{safe_stem}{safe_ext}"


def save_attachment_stream(
    stream,
    *,
    content_length: int,
    filename: str,
    content_type: str = "",
    workspace_uuid: str = "",
    workspace_index: str | int | None = None,
    chunk_size: int = 1024 * 1024,
) -> dict:
    try:
        size = int(content_length)
    except (TypeError, ValueError):
        raise ValueError("content length required")
    if size <= 0:
        raise ValueError("file is empty")
    if size > MAX_ATTACHMENT_BYTES:
        raise ValueError("file exceeds 20 MB limit")

    workspace_key = workspace_attachment_key(workspace_uuid, workspace_index)
    directory = ATTACHMENTS_DIR / workspace_key
    directory.mkdir(parents=True, exist_ok=True)

    stored_filename = safe_attachment_filename(filename)
    final_path = directory / stored_filename
    temp_path = directory / f".{stored_filename}.tmp"

    remaining = size
    written = 0
    try:
        with open(temp_path, "wb") as f:
            while remaining > 0:
                chunk = stream.read(min(chunk_size, remaining))
                if not chunk:
                    break
                f.write(chunk)
                written += len(chunk)
                remaining -= len(chunk)
        if written != size:
            raise ValueError("incomplete upload")
        temp_path.replace(final_path)
    except Exception:
        try:
            temp_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise

    return {
        "id": uuid.uuid4().hex,
        "filename": stored_filename,
        "originalFilename": Path(urllib.parse.unquote(str(filename or ""))).name or "attachment",
        "contentType": str(content_type or "application/octet-stream"),
        "size": size,
        "path": str(final_path.resolve()),
        "workspaceKey": workspace_key,
        "createdAt": _now_iso(),
    }


def cleanup_old_attachments(retention_seconds: int = RETENTION_SECONDS, now: float | None = None) -> dict:
    root = ATTACHMENTS_DIR
    cutoff = (time.time() if now is None else float(now)) - int(retention_seconds)
    deleted_files = 0
    deleted_bytes = 0
    if not root.exists():
        return {"deletedFiles": 0, "deletedBytes": 0}

    for path in sorted(root.rglob("*"), key=lambda item: len(item.parts), reverse=True):
        try:
            if path.is_file() and path.stat().st_mtime < cutoff:
                deleted_bytes += path.stat().st_size
                path.unlink()
                deleted_files += 1
            elif path.is_dir() and path != root:
                try:
                    path.rmdir()
                except OSError:
                    pass
        except OSError:
            continue

    return {"deletedFiles": deleted_files, "deletedBytes": deleted_bytes}
