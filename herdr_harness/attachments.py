"""Bounded, private attachment storage for Herdr workspace prompts."""

from __future__ import annotations

import base64
import binascii
import os
import re
import stat
import tempfile
import threading
import time
import urllib.parse
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping, Optional


MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024
# A 20 MB payload expands to roughly 26.7 MB as base64.  This limit includes
# the small surrounding JSON object while the rest of the API retains 1 MB.
MAX_ATTACHMENT_JSON_BYTES = 29 * 1024 * 1024
DEFAULT_RETENTION_SECONDS = 7 * 24 * 60 * 60
_STORAGE_LOCK = threading.RLock()


class AttachmentError(ValueError):
    def __init__(self, message: str, *, code: str = "invalid_attachment", status: int = 400):
        super().__init__(message)
        self.code = code
        self.status = status


def _safe_component(value: str, fallback: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9._-]+", "-", str(value or "").strip())
    safe = re.sub(r"-+", "-", safe).strip(".-_")
    return safe[:128] or fallback


def _safe_filename(filename: str) -> tuple[str, str]:
    decoded = urllib.parse.unquote(str(filename or "").strip())
    if not decoded or "\x00" in decoded:
        raise AttachmentError("filename is required")
    original = Path(decoded).name
    if not original:
        raise AttachmentError("filename is required")
    stem, extension = os.path.splitext(original)
    stem = re.sub(r"[^A-Za-z0-9._-]+", "_", stem).strip("._-")[:90] or "attachment"
    extension = re.sub(r"[^A-Za-z0-9.]+", "", extension)[:24]
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return original, f"{timestamp}-{uuid.uuid4().hex[:8]}-{stem}{extension}"


def _storage_root(environ: Mapping[str, str]) -> Path:
    configured = str(environ.get("HERDR_HARNESS_ATTACHMENTS_DIR") or "").strip()
    if configured:
        return Path(configured).expanduser().resolve()
    home = Path(environ.get("HOME") or Path.home()).expanduser().resolve()
    return home / ".config" / "herdr-harness" / "attachments"


def retention_seconds(environ: Mapping[str, str]) -> int:
    try:
        value = int(
            environ.get(
                "HERDR_HARNESS_ATTACHMENT_RETENTION_SECONDS",
                str(DEFAULT_RETENTION_SECONDS),
            )
        )
    except (TypeError, ValueError):
        return DEFAULT_RETENTION_SECONDS
    return value if 60 <= value <= 365 * 24 * 60 * 60 else DEFAULT_RETENTION_SECONDS


def _prune_directory(directory: Path, *, cutoff: float) -> tuple[int, int]:
    if directory.is_symlink() or not directory.is_dir():
        return 0, 0
    deleted_files = 0
    deleted_bytes = 0
    try:
        entries = list(directory.iterdir())
    except OSError:
        return 0, 0
    for path in entries:
        try:
            metadata = os.lstat(path)
        except OSError:
            continue
        # Attachments are stored directly in their workspace directory.  Do
        # not follow symlinks or recurse into unexpected directories.
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_mtime >= cutoff:
            continue
        try:
            path.unlink()
        except OSError:
            continue
        deleted_files += 1
        deleted_bytes += metadata.st_size
    try:
        directory.rmdir()
    except OSError:
        pass
    return deleted_files, deleted_bytes


def prune_expired_attachments(
    *,
    environ: Optional[Mapping[str, str]] = None,
    workspace_id: Optional[str] = None,
    retention: Optional[int] = None,
    now: Optional[float] = None,
) -> dict:
    """Delete expired attachment files without crossing workspace boundaries.

    Cleanup shares a process lock with uploads, never follows symlinks, and
    only removes regular files older than the configured TTL.  A workspace ID
    limits pruning to that workspace; omitting it performs lifecycle cleanup
    across direct workspace children of the attachment root.
    """

    environment = os.environ if environ is None else environ
    keep_seconds = retention_seconds(environment) if retention is None else max(1, int(retention))
    cutoff = (time.time() if now is None else float(now)) - keep_seconds
    root = _storage_root(environment)
    deleted_files = 0
    deleted_bytes = 0
    with _STORAGE_LOCK:
        if workspace_id is not None:
            directories = [root / _safe_component(workspace_id, "workspace")]
        else:
            try:
                directories = [
                    path
                    for path in root.iterdir()
                    if not path.is_symlink() and path.is_dir()
                ]
            except OSError:
                directories = []
        for directory in directories:
            files, size = _prune_directory(directory, cutoff=cutoff)
            deleted_files += files
            deleted_bytes += size
    return {
        "deleted_files": deleted_files,
        "deleted_bytes": deleted_bytes,
        "workspace_id": workspace_id,
    }


def save_base64_attachment(
    *,
    workspace_id: str,
    filename: str,
    content_type: str,
    data_base64: str,
    environ: Optional[Mapping[str, str]] = None,
) -> dict:
    if not isinstance(data_base64, str) or not data_base64:
        raise AttachmentError("data_base64 is required")
    # Reject impossible input before allocating the decoded buffer.
    maximum_encoded = ((MAX_ATTACHMENT_BYTES + 2) // 3) * 4
    if len(data_base64) > maximum_encoded:
        raise AttachmentError(
            "file exceeds 20 MB limit",
            code="attachment_too_large",
            status=413,
        )
    try:
        payload = base64.b64decode(data_base64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise AttachmentError("data_base64 must be valid base64") from exc
    if not payload:
        raise AttachmentError("file is empty")
    if len(payload) > MAX_ATTACHMENT_BYTES:
        raise AttachmentError(
            "file exceeds 20 MB limit",
            code="attachment_too_large",
            status=413,
        )

    original, stored = _safe_filename(filename)
    normalized_type = str(content_type or "application/octet-stream").strip()
    if "\x00" in normalized_type or len(normalized_type) > 255:
        raise AttachmentError("content_type is invalid")
    environment = os.environ if environ is None else environ
    workspace_key = _safe_component(workspace_id, "workspace")
    directory = _storage_root(environment) / workspace_key
    try:
        with _STORAGE_LOCK:
            _prune_directory(
                directory,
                cutoff=time.time() - retention_seconds(environment),
            )
            directory.mkdir(parents=True, exist_ok=True)
            if directory.is_symlink() or not directory.is_dir():
                raise OSError("workspace attachment directory is invalid")
            os.chmod(directory, 0o700)
            descriptor, temporary_name = tempfile.mkstemp(
                prefix=f".{stored}.",
                suffix=".tmp",
                dir=directory,
            )
            temporary = Path(temporary_name)
            try:
                with os.fdopen(descriptor, "wb") as handle:
                    handle.write(payload)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.chmod(temporary, 0o600)
                final_path = directory / stored
                os.replace(temporary, final_path)
                os.chmod(final_path, 0o600)
            finally:
                try:
                    temporary.unlink(missing_ok=True)
                except OSError:
                    pass
    except OSError as exc:
        raise AttachmentError(
            f"Could not save attachment: {exc}",
            code="attachment_write_failed",
            status=500,
        ) from exc

    created_at = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    return {
        "id": uuid.uuid4().hex,
        "filename": stored,
        "original_filename": original,
        "content_type": normalized_type or "application/octet-stream",
        "size": len(payload),
        "path": str(final_path.resolve()),
        "workspace_id": workspace_id,
        "created_at": created_at,
    }
