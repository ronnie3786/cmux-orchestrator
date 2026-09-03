"""Durable, private storage for files and links presented by agents.

The source path used to register a file is deliberately never persisted.  A
private copy is made before the artifact is exposed to HTTP clients so results
remain available after an agent exits or its workspace changes.
"""

from __future__ import annotations

import hashlib
import json
import mimetypes
import os
import re
import stat
import threading
import time
import urllib.parse
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, BinaryIO, Mapping, Optional

from .alerts import utc_now


DEFAULT_MAX_FILE_BYTES = 512 * 1024 * 1024
DEFAULT_MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
DEFAULT_MAX_ARTIFACTS = 256
DEFAULT_RETENTION_DAYS = 30
MAX_TITLE_CHARACTERS = 240
MAX_ORIGIN_ID_CHARACTERS = 256
MAX_SESSION_ID_CHARACTERS = 512
MAX_LOCATION_CHARACTERS = 16_384
MAX_IDEMPOTENCY_KEY_CHARACTERS = 256

_ARTIFACT_ID_RE = re.compile(r"^art_[0-9a-f]{24}$")
_BLOB_NAME_RE = re.compile(r"^art_[0-9a-f]{24}\.blob$")
_BLOB_TEMP_NAME_RE = re.compile(
    r"^\.art_[0-9a-f]{24}\.[0-9a-f]{32}\.tmp$"
)
_INDEX_TEMP_NAME_RE = re.compile(r"^\.index\.[0-9a-f]{32}\.tmp$")
_ORIGIN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:._-]{0,255}$")
_IDEMPOTENCY_KEY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:._-]{0,255}$")
_CONTROL_CHARACTER_RE = re.compile(r"[\x00-\x1f\x7f]")

# Registration is intentionally allowlist-based. Unknown formats remain
# unsupported until their native-open behavior and risk profile are reviewed.
_ALLOWED_EXTENSIONS = frozenset(
    {
        # Documents and structured text.
        ".csv",
        ".doc",
        ".docx",
        ".epub",
        ".htm",
        ".html",
        ".json",
        ".key",
        ".markdown",
        ".md",
        ".numbers",
        ".odg",
        ".odp",
        ".ods",
        ".odt",
        ".pages",
        ".pdf",
        ".ppt",
        ".pptx",
        ".rtf",
        ".tex",
        ".text",
        ".tsv",
        ".txt",
        ".xls",
        ".xlsx",
        ".xml",
        ".yaml",
        ".yml",
        # Images.
        ".avif",
        ".bmp",
        ".gif",
        ".heic",
        ".heif",
        ".jpeg",
        ".jpg",
        ".png",
        ".svg",
        ".tif",
        ".tiff",
        ".webp",
        # Video.
        ".avi",
        ".m4v",
        ".mkv",
        ".mov",
        ".mp4",
        ".mpeg",
        ".mpg",
        ".webm",
        # Audio.
        ".aac",
        ".aif",
        ".aiff",
        ".flac",
        ".m4a",
        ".mp3",
        ".oga",
        ".ogg",
        ".opus",
        ".wav",
        # Archives.
        ".7z",
        ".bz2",
        ".gz",
        ".tar",
        ".tgz",
        ".xz",
        ".zip",
    }
)

_CONTENT_TYPE_OVERRIDES = {
    ".7z": "application/x-7z-compressed",
    ".avif": "image/avif",
    ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".epub": "application/epub+zip",
    ".heic": "image/heic",
    ".heif": "image/heif",
    ".key": "application/vnd.apple.keynote",
    ".m4a": "audio/mp4",
    ".markdown": "text/markdown",
    ".md": "text/markdown",
    ".mkv": "video/x-matroska",
    ".numbers": "application/vnd.apple.numbers",
    ".pages": "application/vnd.apple.pages",
    ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ".webp": "image/webp",
    ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
}

_EXECUTABLE_MAGICS = (
    b"\x7fELF",
    b"MZ",
    b"\xca\xfe\xba\xbe",
    b"\xce\xfa\xed\xfe",
    b"\xcf\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce",
    b"\xfe\xed\xfa\xcf",
)


class ResultArtifactError(ValueError):
    def __init__(
        self,
        message: str,
        *,
        code: str = "invalid_result_artifact",
        status: int = 400,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.status = status


@dataclass
class ResultArtifactContent:
    """An already validated file handle and its public metadata."""

    artifact: dict[str, Any]
    handle: BinaryIO
    byte_size: int

    def close(self) -> None:
        self.handle.close()

    def __enter__(self) -> "ResultArtifactContent":
        return self

    def __exit__(self, *_args: Any) -> None:
        self.close()


def _configured_int(
    environ: Mapping[str, str],
    name: str,
    default: int,
    *,
    minimum: int,
    maximum: int,
) -> int:
    try:
        value = int(environ.get(name, str(default)))
    except (TypeError, ValueError):
        return default
    return value if minimum <= value <= maximum else default


def _required_string(value: Any, label: str, maximum: int) -> str:
    if not isinstance(value, str):
        raise ResultArtifactError(f"{label} must be a string")
    text = value.strip()
    if not text:
        raise ResultArtifactError(f"{label} is required")
    if len(text) > maximum:
        raise ResultArtifactError(f"{label} exceeds {maximum} characters")
    if _CONTROL_CHARACTER_RE.search(text):
        raise ResultArtifactError(f"{label} contains a control character")
    return text


def _optional_string(value: Any, label: str, maximum: int) -> Optional[str]:
    if value is None:
        return None
    return _required_string(value, label, maximum)


def _parse_created_at(value: Any) -> Optional[datetime]:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _public_metadata(record: Mapping[str, Any]) -> dict[str, Any]:
    metadata = {
        "id": record.get("id"),
        "originType": record.get("originType"),
        "originId": record.get("originId"),
        "sessionId": record.get("sessionId"),
        "kind": record.get("kind"),
        "title": record.get("title"),
        "filename": record.get("filename"),
        "contentType": record.get("contentType"),
        "byteSize": record.get("byteSize"),
        "createdAt": record.get("createdAt"),
    }
    if record.get("kind") == "file":
        metadata["downloadPath"] = record.get("downloadPath")
    elif record.get("kind") == "link":
        metadata["url"] = record.get("url")
    return metadata


def _record_sort_key(record: Mapping[str, Any]) -> tuple[str, int]:
    created_ns = record.get("_createdNs")
    return (
        str(record.get("createdAt") or ""),
        created_ns if isinstance(created_ns, int) else 0,
    )


class ResultArtifactStore:
    """Thread-safe JSON metadata and immutable artifact blobs."""

    def __init__(
        self,
        root: Optional[str | os.PathLike[str]] = None,
        *,
        environ: Optional[Mapping[str, str]] = None,
    ) -> None:
        self.environ = dict(os.environ if environ is None else environ)
        configured_root = self.environ.get("HERDR_HARNESS_RESULT_ARTIFACTS_ROOT")
        if root is None:
            if configured_root:
                root = configured_root
            else:
                home = self.environ.get("HOME")
                root = (
                    Path(home) / ".config" / "herdr-harness" / "result-artifacts"
                    if home
                    else Path("~/.config/herdr-harness/result-artifacts").expanduser()
                )
        self.root = Path(root).expanduser()
        if not self.root.is_absolute():
            raise ResultArtifactError(
                "result artifact storage root must be absolute",
                code="result_artifact_storage_invalid",
                status=500,
            )
        self.files_root = self.root / "files"
        self.index_path = self.root / "index.json"
        self.max_file_bytes = _configured_int(
            self.environ,
            "HERDR_HARNESS_RESULT_ARTIFACT_MAX_FILE_BYTES",
            DEFAULT_MAX_FILE_BYTES,
            minimum=1,
            maximum=4 * 1024 * 1024 * 1024,
        )
        self.max_total_bytes = max(
            self.max_file_bytes,
            _configured_int(
                self.environ,
                "HERDR_HARNESS_RESULT_ARTIFACT_MAX_TOTAL_BYTES",
                DEFAULT_MAX_TOTAL_BYTES,
                minimum=1,
                maximum=16 * 1024 * 1024 * 1024,
            ),
        )
        self.maximum_artifacts = _configured_int(
            self.environ,
            "HERDR_HARNESS_RESULT_ARTIFACT_MAX_COUNT",
            DEFAULT_MAX_ARTIFACTS,
            minimum=1,
            maximum=10_000,
        )
        self.retention_days = _configured_int(
            self.environ,
            "HERDR_HARNESS_RESULT_ARTIFACT_RETENTION_DAYS",
            DEFAULT_RETENTION_DAYS,
            minimum=1,
            maximum=3650,
        )
        self._lock = threading.RLock()
        # Validate the private storage boundary and clean debris from a prior
        # interrupted write immediately. The same checks run on later access
        # so replacing either managed directory with a symlink is never
        # silently accepted after startup.
        with self._lock:
            self._ensure_directories()
            self._retained_records_locked()

    def create(
        self,
        *,
        origin_type: Any,
        origin_id: Any,
        session_id: Any = None,
        kind: Any,
        location: Any,
        title: Any = None,
        idempotency_key: Any = None,
    ) -> dict[str, Any]:
        artifact, _created = self.create_with_status(
            origin_type=origin_type,
            origin_id=origin_id,
            session_id=session_id,
            kind=kind,
            location=location,
            title=title,
            idempotency_key=idempotency_key,
        )
        return artifact

    def create_with_status(
        self,
        *,
        origin_type: Any,
        origin_id: Any,
        session_id: Any = None,
        kind: Any,
        location: Any,
        title: Any = None,
        idempotency_key: Any = None,
    ) -> tuple[dict[str, Any], bool]:
        origin_type_value = _required_string(origin_type, "originType", 32)
        if origin_type_value not in {"pane", "agent_run"}:
            raise ResultArtifactError("originType must be pane or agent_run")
        origin_id_value = _required_string(
            origin_id, "originId", MAX_ORIGIN_ID_CHARACTERS
        )
        if not _ORIGIN_ID_RE.fullmatch(origin_id_value):
            raise ResultArtifactError("originId is invalid")
        session_id_value = _optional_string(
            session_id, "sessionId", MAX_SESSION_ID_CHARACTERS
        )
        kind_value = _required_string(kind, "kind", 16)
        if kind_value not in {"file", "link"}:
            raise ResultArtifactError("kind must be file or link")
        location_value = _required_string(
            location, "location", MAX_LOCATION_CHARACTERS
        )
        title_value = _optional_string(title, "title", MAX_TITLE_CHARACTERS)
        idempotency_key_value = _optional_string(
            idempotency_key,
            "idempotencyKey",
            MAX_IDEMPOTENCY_KEY_CHARACTERS,
        )
        if (
            idempotency_key_value is not None
            and not _IDEMPOTENCY_KEY_RE.fullmatch(idempotency_key_value)
        ):
            raise ResultArtifactError("idempotencyKey is invalid")
        request_fingerprint = self._request_fingerprint(
            origin_type=origin_type_value,
            origin_id=origin_id_value,
            session_id=session_id_value,
            kind=kind_value,
            location=location_value,
            title=title_value,
        )

        # A file registration owns the store lock from capacity inspection
        # through private copy and index commit. This deliberately serializes
        # potentially large copies: otherwise several request threads can each
        # materialize a blob before any of them sees the others in the index,
        # allowing physical storage to run far ahead of its configured bounds.
        with self._lock:
            records = self._retained_records_locked()
            if idempotency_key_value is not None:
                existing = self._idempotent_record_locked(
                    records,
                    origin_type=origin_type_value,
                    origin_id=origin_id_value,
                    idempotency_key=idempotency_key_value,
                    request_fingerprint=request_fingerprint,
                )
                if existing is not None:
                    return _public_metadata(existing), False

            artifact_id = f"art_{uuid.uuid4().hex[:24]}"
            created_at = utc_now()
            blob_name: Optional[str] = None
            try:
                if kind_value == "file":
                    file_fields, blob_name, records = self._copy_file(
                        location_value,
                        artifact_id,
                        records,
                    )
                    derived_title = file_fields["filename"]
                    record: dict[str, Any] = {
                        "id": artifact_id,
                        "originType": origin_type_value,
                        "originId": origin_id_value,
                        "sessionId": session_id_value,
                        "kind": kind_value,
                        "title": title_value or derived_title[:MAX_TITLE_CHARACTERS],
                        **file_fields,
                        "createdAt": created_at,
                        "_createdNs": time.time_ns(),
                        "downloadPath": f"/api/v1/result-artifacts/{artifact_id}/content",
                        "_blobName": blob_name,
                    }
                else:
                    url, derived_title = self._validate_link(location_value)
                    record = {
                        "id": artifact_id,
                        "originType": origin_type_value,
                        "originId": origin_id_value,
                        "sessionId": session_id_value,
                        "kind": kind_value,
                        "title": title_value or derived_title[:MAX_TITLE_CHARACTERS],
                        "filename": None,
                        "contentType": None,
                        "byteSize": None,
                        "createdAt": created_at,
                        "_createdNs": time.time_ns(),
                        "url": url,
                    }

                if idempotency_key_value is not None:
                    record["_idempotencyKey"] = idempotency_key_value
                    record["_requestFingerprint"] = request_fingerprint

                records.append(record)
                records, removed = self._partition_retained_locked(records)
                self._write_records_locked(records)
                self._delete_record_blobs(removed)
            except Exception:
                if blob_name is not None:
                    self._delete_blob(blob_name)
                raise
            return _public_metadata(record), True

    def list(self) -> list[dict[str, Any]]:
        with self._lock:
            records = self._retained_records_locked()
            return [_public_metadata(item) for item in records]

    def open_content(self, artifact_id: Any) -> ResultArtifactContent:
        artifact_id_value = str(artifact_id or "")
        if not _ARTIFACT_ID_RE.fullmatch(artifact_id_value):
            raise ResultArtifactError(
                "Result artifact not found",
                code="result_artifact_not_found",
                status=404,
            )
        with self._lock:
            # Retention is enforced on direct content access too. A caller with
            # a previously known authenticated URL must not be able to extend
            # an artifact's lifetime merely because no list request occurred.
            records = self._retained_records_locked()
            record = next(
                (item for item in records if item.get("id") == artifact_id_value),
                None,
            )
            if record is None or record.get("kind") != "file":
                raise ResultArtifactError(
                    "Result artifact not found",
                    code="result_artifact_not_found",
                    status=404,
                )
            blob_name = record.get("_blobName")
            if not isinstance(blob_name, str) or not _BLOB_NAME_RE.fullmatch(blob_name):
                raise ResultArtifactError(
                    "Result artifact content is unavailable",
                    code="result_artifact_content_unavailable",
                    status=404,
                )
            flags = os.O_RDONLY
            if hasattr(os, "O_CLOEXEC"):
                flags |= os.O_CLOEXEC
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            files_descriptor = self._open_files_directory()
            try:
                descriptor = os.open(
                    blob_name,
                    flags,
                    dir_fd=files_descriptor,
                )
            except (FileNotFoundError, NotADirectoryError, OSError) as exc:
                raise ResultArtifactError(
                    "Result artifact content is unavailable",
                    code="result_artifact_content_unavailable",
                    status=404,
                ) from exc
            finally:
                os.close(files_descriptor)
            try:
                info = os.fstat(descriptor)
                if not stat.S_ISREG(info.st_mode):
                    raise ResultArtifactError(
                        "Result artifact content is unavailable",
                        code="result_artifact_content_unavailable",
                        status=404,
                    )
                expected_size = record.get("byteSize")
                if not isinstance(expected_size, int) or info.st_size != expected_size:
                    raise ResultArtifactError(
                        "Result artifact content is unavailable",
                        code="result_artifact_content_unavailable",
                        status=404,
                    )
                handle = os.fdopen(descriptor, "rb")
                descriptor = -1
                return ResultArtifactContent(
                    artifact=_public_metadata(record),
                    handle=handle,
                    byte_size=info.st_size,
                )
            finally:
                if descriptor >= 0:
                    os.close(descriptor)

    def _copy_file(
        self,
        location: str,
        artifact_id: str,
        records: list[dict[str, Any]],
    ) -> tuple[dict[str, Any], str, list[dict[str, Any]]]:
        source = Path(location)
        if not source.is_absolute():
            raise ResultArtifactError("file location must be an absolute path")
        if ".." in source.parts:
            raise ResultArtifactError("file location must not contain traversal")
        filename = source.name
        if not filename or filename in {".", ".."}:
            raise ResultArtifactError("file location must name a file")
        extension = source.suffix.lower()
        if extension not in _ALLOWED_EXTENSIONS:
            raise ResultArtifactError(
                "file type is not supported",
                code="result_artifact_type_unsupported",
                status=415,
            )
        try:
            source_info = os.lstat(source)
        except FileNotFoundError as exc:
            raise ResultArtifactError(
                "file location does not exist",
                code="result_artifact_source_not_found",
                status=404,
            ) from exc
        except OSError as exc:
            raise ResultArtifactError(
                "file location cannot be inspected",
                code="result_artifact_source_unavailable",
                status=400,
            ) from exc
        if stat.S_ISLNK(source_info.st_mode):
            raise ResultArtifactError("file location must not be a symbolic link")
        if not stat.S_ISREG(source_info.st_mode):
            raise ResultArtifactError("file location must be a regular file")
        if source_info.st_size > self.max_file_bytes:
            raise ResultArtifactError(
                "file exceeds the configured result artifact size limit",
                code="result_artifact_too_large",
                status=413,
            )

        flags = os.O_RDONLY
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            source_descriptor = os.open(source, flags)
        except OSError as exc:
            raise ResultArtifactError(
                "file location cannot be opened",
                code="result_artifact_source_unavailable",
                status=400,
            ) from exc

        blob_name = f"{artifact_id}.blob"
        temporary_name = f".{artifact_id}.{uuid.uuid4().hex}.tmp"
        files_descriptor = -1
        destination_descriptor = -1
        copied = 0
        try:
            opened_info = os.fstat(source_descriptor)
            if not stat.S_ISREG(opened_info.st_mode):
                raise ResultArtifactError("file location must be a regular file")
            if opened_info.st_size > self.max_file_bytes:
                raise ResultArtifactError(
                    "file exceeds the configured result artifact size limit",
                    code="result_artifact_too_large",
                    status=413,
                )
            reserved_size = opened_info.st_size
            first_chunk = os.read(
                source_descriptor,
                min(1024 * 1024, reserved_size),
            )
            if first_chunk:
                self._reject_executable_magic(first_chunk)

            # Source validation and executable sniffing happen before this
            # admission point. From here onward, the exact opened size owns
            # one record slot and its bytes in the managed store.
            records = self._reserve_file_capacity_locked(
                records,
                required_bytes=reserved_size,
            )
            files_descriptor = self._open_files_directory()
            destination_descriptor = os.open(
                temporary_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
                dir_fd=files_descriptor,
            )
            if first_chunk:
                self._write_blob_chunk(destination_descriptor, first_chunk)
                copied = len(first_chunk)
            while copied < reserved_size:
                chunk = os.read(
                    source_descriptor,
                    min(1024 * 1024, reserved_size - copied),
                )
                if not chunk:
                    break
                self._write_blob_chunk(destination_descriptor, chunk)
                copied += len(chunk)
            grew_after_reservation = bool(os.read(source_descriptor, 1))
            if copied != reserved_size or grew_after_reservation:
                raise ResultArtifactError(
                    "file changed while it was being registered",
                    code="result_artifact_source_changed",
                    status=409,
                )
            os.fsync(destination_descriptor)
            os.fchmod(destination_descriptor, 0o600)
            os.close(destination_descriptor)
            destination_descriptor = -1
            os.replace(
                temporary_name,
                blob_name,
                src_dir_fd=files_descriptor,
                dst_dir_fd=files_descriptor,
            )
            os.fsync(files_descriptor)
        except Exception:
            if files_descriptor >= 0:
                try:
                    os.unlink(temporary_name, dir_fd=files_descriptor)
                except FileNotFoundError:
                    pass
            raise
        finally:
            os.close(source_descriptor)
            if destination_descriptor >= 0:
                os.close(destination_descriptor)
            if files_descriptor >= 0:
                os.close(files_descriptor)

        content_type = _CONTENT_TYPE_OVERRIDES.get(extension)
        if content_type is None:
            content_type = mimetypes.guess_type(filename, strict=False)[0]
        return (
            {
                "filename": filename,
                "contentType": content_type or "application/octet-stream",
                "byteSize": copied,
            },
            blob_name,
            records,
        )

    @staticmethod
    def _write_blob_chunk(descriptor: int, chunk: bytes) -> None:
        view = memoryview(chunk)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]

    @staticmethod
    def _reject_executable_magic(chunk: bytes) -> None:
        if chunk.startswith(b"#!") or any(chunk.startswith(item) for item in _EXECUTABLE_MAGICS):
            raise ResultArtifactError(
                "executable files cannot be presented as result artifacts",
                code="result_artifact_type_unsupported",
                status=415,
            )

    @staticmethod
    def _validate_link(location: str) -> tuple[str, str]:
        try:
            parsed = urllib.parse.urlsplit(location)
        except ValueError as exc:
            raise ResultArtifactError("link location is invalid") from exc
        if parsed.scheme.lower() not in {"http", "https"}:
            raise ResultArtifactError("link location must use http or https")
        if not parsed.netloc or parsed.username is not None or parsed.password is not None:
            raise ResultArtifactError("link location must have a public host and no credentials")
        try:
            hostname = parsed.hostname
            port = parsed.port
        except ValueError as exc:
            raise ResultArtifactError("link location is invalid") from exc
        if not hostname or _CONTROL_CHARACTER_RE.search(location):
            raise ResultArtifactError("link location is invalid")
        host = hostname.encode("idna").decode("ascii").lower()
        netloc = host
        if ":" in host and not host.startswith("["):
            netloc = f"[{host}]"
        if port is not None:
            netloc = f"{netloc}:{port}"
        normalized = urllib.parse.urlunsplit(
            (parsed.scheme.lower(), netloc, parsed.path or "", parsed.query, parsed.fragment)
        )
        path_name = Path(urllib.parse.unquote(parsed.path)).name.strip()
        return normalized, path_name or host

    @staticmethod
    def _request_fingerprint(
        *,
        origin_type: str,
        origin_id: str,
        session_id: Optional[str],
        kind: str,
        location: str,
        title: Optional[str],
    ) -> str:
        canonical = json.dumps(
            [origin_type, origin_id, session_id, kind, location, title],
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        return hashlib.sha256(canonical).hexdigest()

    @staticmethod
    def _idempotent_record_locked(
        records: list[dict[str, Any]],
        *,
        origin_type: str,
        origin_id: str,
        idempotency_key: str,
        request_fingerprint: str,
    ) -> Optional[dict[str, Any]]:
        existing = next(
            (
                item
                for item in records
                if item.get("originType") == origin_type
                and item.get("originId") == origin_id
                and item.get("_idempotencyKey") == idempotency_key
            ),
            None,
        )
        if existing is None:
            return None
        if existing.get("_requestFingerprint") != request_fingerprint:
            raise ResultArtifactError(
                "idempotencyKey was already used for a different result artifact request",
                code="result_artifact_idempotency_conflict",
                status=409,
            )
        return existing

    def _ensure_directories(self) -> None:
        try:
            self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
            root_descriptor = self._open_directory_no_follow(
                self.root,
                "result artifact storage root",
            )
            try:
                try:
                    files_info = os.stat(
                        "files",
                        dir_fd=root_descriptor,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    os.mkdir("files", mode=0o700, dir_fd=root_descriptor)
                    files_info = os.stat(
                        "files",
                        dir_fd=root_descriptor,
                        follow_symlinks=False,
                    )
                if stat.S_ISLNK(files_info.st_mode):
                    raise ResultArtifactError(
                        "result artifact files directory must not be a symbolic link",
                        code="result_artifact_storage_invalid",
                        status=500,
                    )
                if not stat.S_ISDIR(files_info.st_mode):
                    raise ResultArtifactError(
                        "result artifact files directory must be a directory",
                        code="result_artifact_storage_invalid",
                        status=500,
                    )
                files_descriptor = os.open(
                    "files",
                    self._directory_open_flags(),
                    dir_fd=root_descriptor,
                )
                try:
                    if not stat.S_ISDIR(os.fstat(files_descriptor).st_mode):
                        raise ResultArtifactError(
                            "result artifact files directory must be a directory",
                            code="result_artifact_storage_invalid",
                            status=500,
                        )
                    os.fchmod(root_descriptor, 0o700)
                    os.fchmod(files_descriptor, 0o700)
                finally:
                    os.close(files_descriptor)
            finally:
                os.close(root_descriptor)
        except ResultArtifactError:
            raise
        except OSError as exc:
            raise ResultArtifactError(
                "result artifact storage is unavailable",
                code="result_artifact_storage_unavailable",
                status=500,
            ) from exc

    @staticmethod
    def _directory_open_flags() -> int:
        flags = os.O_RDONLY
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        if hasattr(os, "O_DIRECTORY"):
            flags |= os.O_DIRECTORY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        return flags

    @classmethod
    def _open_directory_no_follow(cls, path: Path, label: str) -> int:
        try:
            info = os.lstat(path)
        except OSError as exc:
            raise ResultArtifactError(
                "result artifact storage is unavailable",
                code="result_artifact_storage_unavailable",
                status=500,
            ) from exc
        if stat.S_ISLNK(info.st_mode):
            raise ResultArtifactError(
                f"{label} must not be a symbolic link",
                code="result_artifact_storage_invalid",
                status=500,
            )
        if not stat.S_ISDIR(info.st_mode):
            raise ResultArtifactError(
                f"{label} must be a directory",
                code="result_artifact_storage_invalid",
                status=500,
            )
        try:
            descriptor = os.open(path, cls._directory_open_flags())
        except OSError as exc:
            raise ResultArtifactError(
                "result artifact storage is unavailable",
                code="result_artifact_storage_unavailable",
                status=500,
            ) from exc
        if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
            os.close(descriptor)
            raise ResultArtifactError(
                f"{label} must be a directory",
                code="result_artifact_storage_invalid",
                status=500,
            )
        return descriptor

    def _open_files_directory(self) -> int:
        self._ensure_directories()
        root_descriptor = self._open_directory_no_follow(
            self.root,
            "result artifact storage root",
        )
        try:
            try:
                descriptor = os.open(
                    "files",
                    self._directory_open_flags(),
                    dir_fd=root_descriptor,
                )
            except OSError as exc:
                raise ResultArtifactError(
                    "result artifact storage is unavailable",
                    code="result_artifact_storage_unavailable",
                    status=500,
                ) from exc
            if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
                os.close(descriptor)
                raise ResultArtifactError(
                    "result artifact files directory must be a directory",
                    code="result_artifact_storage_invalid",
                    status=500,
                )
            return descriptor
        finally:
            os.close(root_descriptor)

    def _load_records_locked(self) -> list[dict[str, Any]]:
        self._ensure_directories()
        root_descriptor = self._open_directory_no_follow(
            self.root,
            "result artifact storage root",
        )
        descriptor = -1
        try:
            flags = os.O_RDONLY
            if hasattr(os, "O_CLOEXEC"):
                flags |= os.O_CLOEXEC
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            descriptor = os.open(
                "index.json",
                flags,
                dir_fd=root_descriptor,
            )
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise ResultArtifactError(
                    "result artifact metadata is unavailable",
                    code="result_artifact_storage_unavailable",
                    status=500,
                )
            with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
                descriptor = -1
                payload = json.load(handle)
        except FileNotFoundError:
            return []
        except ResultArtifactError:
            raise
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ResultArtifactError(
                "result artifact metadata is unavailable",
                code="result_artifact_storage_unavailable",
                status=500,
            ) from exc
        finally:
            if descriptor >= 0:
                os.close(descriptor)
            os.close(root_descriptor)
        values = payload.get("artifacts") if isinstance(payload, dict) else None
        if not isinstance(values, list):
            raise ResultArtifactError(
                "result artifact metadata is invalid",
                code="result_artifact_storage_unavailable",
                status=500,
            )
        records = [dict(item) for item in values if isinstance(item, dict)]
        records.sort(key=_record_sort_key, reverse=True)
        return records

    def _retained_records_locked(self) -> list[dict[str, Any]]:
        records = self._load_records_locked()
        retained, removed = self._partition_retained_locked(records)
        if len(retained) != len(records):
            self._write_records_locked(retained)
            self._delete_record_blobs(removed)
        self._sweep_orphans_locked(retained)
        return retained

    def _write_records_locked(self, records: list[dict[str, Any]]) -> None:
        self._ensure_directories()
        root_descriptor = self._open_directory_no_follow(
            self.root,
            "result artifact storage root",
        )
        temporary_name = f".index.{uuid.uuid4().hex}.tmp"
        data = json.dumps(
            {"version": 1, "artifacts": records},
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        descriptor = -1
        try:
            descriptor = os.open(
                temporary_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
                dir_fd=root_descriptor,
            )
            view = memoryview(data)
            while view:
                written = os.write(descriptor, view)
                view = view[written:]
            os.fsync(descriptor)
            os.fchmod(descriptor, 0o600)
            os.close(descriptor)
            descriptor = -1
            os.replace(
                temporary_name,
                "index.json",
                src_dir_fd=root_descriptor,
                dst_dir_fd=root_descriptor,
            )
            os.fsync(root_descriptor)
        except OSError as exc:
            try:
                os.unlink(temporary_name, dir_fd=root_descriptor)
            except FileNotFoundError:
                pass
            raise ResultArtifactError(
                "result artifact metadata could not be saved",
                code="result_artifact_storage_unavailable",
                status=500,
            ) from exc
        finally:
            if descriptor >= 0:
                os.close(descriptor)
            os.close(root_descriptor)

    def _reserve_file_capacity_locked(
        self,
        records: list[dict[str, Any]],
        *,
        required_bytes: int,
    ) -> list[dict[str, Any]]:
        retained = sorted(records, key=_record_sort_key, reverse=True)
        retained_bytes = sum(self._record_byte_size(item) for item in retained)
        removed: list[dict[str, Any]] = []
        while retained and (
            len(retained) + 1 > self.maximum_artifacts
            or retained_bytes + required_bytes > self.max_total_bytes
        ):
            oldest = retained.pop()
            retained_bytes -= self._record_byte_size(oldest)
            removed.append(oldest)

        if (
            len(retained) + 1 > self.maximum_artifacts
            or retained_bytes + required_bytes > self.max_total_bytes
        ):
            raise ResultArtifactError(
                "file cannot fit within the configured result artifact storage limits",
                code="result_artifact_too_large",
                status=413,
            )

        if removed:
            # Commit the eviction before copying. If the process crashes after
            # this point, startup sweeping removes any unindexed new blob.
            self._write_records_locked(retained)
            self._delete_record_blobs(removed)
            self._sweep_orphans_locked(retained)

        managed_bytes = self._managed_blob_bytes_locked()
        if managed_bytes + required_bytes > self.max_total_bytes:
            raise ResultArtifactError(
                "result artifact storage could not reserve the requested capacity",
                code="result_artifact_storage_unavailable",
                status=500,
            )
        return retained

    def _managed_blob_bytes_locked(self) -> int:
        files_descriptor = self._open_files_directory()
        try:
            total = 0
            with os.scandir(files_descriptor) as entries:
                for entry in entries:
                    if not (
                        _BLOB_NAME_RE.fullmatch(entry.name)
                        or _BLOB_TEMP_NAME_RE.fullmatch(entry.name)
                    ):
                        continue
                    try:
                        total += entry.stat(follow_symlinks=False).st_size
                    except FileNotFoundError:
                        pass
            return total
        finally:
            os.close(files_descriptor)

    @staticmethod
    def _record_byte_size(record: Mapping[str, Any]) -> int:
        value = record.get("byteSize")
        return value if isinstance(value, int) and value >= 0 else 0

    def _partition_retained_locked(
        self, records: list[dict[str, Any]]
    ) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        cutoff = datetime.now(timezone.utc) - timedelta(days=self.retention_days)
        ordered = sorted(
            records,
            key=_record_sort_key,
            reverse=True,
        )
        retained: list[dict[str, Any]] = []
        removed: list[dict[str, Any]] = []
        retained_bytes = 0
        for item in ordered:
            created = _parse_created_at(item.get("createdAt"))
            size = self._record_byte_size(item)
            should_keep = bool(
                created is not None
                and created >= cutoff
                and len(retained) < self.maximum_artifacts
                and retained_bytes + size <= self.max_total_bytes
            )
            if should_keep:
                retained.append(item)
                retained_bytes += size
            else:
                removed.append(item)
        return retained, removed

    def _delete_record_blobs(self, records: list[dict[str, Any]]) -> None:
        for item in records:
            blob_name = item.get("_blobName")
            if isinstance(blob_name, str):
                self._delete_blob(blob_name)

    def _sweep_orphans_locked(self, records: list[dict[str, Any]]) -> None:
        referenced_blobs = {
            blob_name
            for item in records
            if isinstance((blob_name := item.get("_blobName")), str)
            and _BLOB_NAME_RE.fullmatch(blob_name)
        }

        files_descriptor = self._open_files_directory()
        try:
            with os.scandir(files_descriptor) as entries:
                candidates = [
                    entry.name
                    for entry in entries
                    if _BLOB_TEMP_NAME_RE.fullmatch(entry.name)
                    or (
                        _BLOB_NAME_RE.fullmatch(entry.name)
                        and entry.name not in referenced_blobs
                    )
                ]
            for name in candidates:
                try:
                    # unlink removes the directory entry itself and never
                    # follows a malicious symlink masquerading as an orphan.
                    os.unlink(name, dir_fd=files_descriptor)
                except FileNotFoundError:
                    pass
                except OSError:
                    # Cleanup is best effort. Unindexed entries are never
                    # exposed, even if the filesystem temporarily refuses
                    # their deletion.
                    pass
        finally:
            os.close(files_descriptor)

        root_descriptor = self._open_directory_no_follow(
            self.root,
            "result artifact storage root",
        )
        try:
            with os.scandir(root_descriptor) as entries:
                temporary_indexes = [
                    entry.name
                    for entry in entries
                    if _INDEX_TEMP_NAME_RE.fullmatch(entry.name)
                ]
            for name in temporary_indexes:
                try:
                    os.unlink(name, dir_fd=root_descriptor)
                except FileNotFoundError:
                    pass
                except OSError:
                    pass
        finally:
            os.close(root_descriptor)

    def _delete_blob(self, blob_name: str) -> None:
        if not _BLOB_NAME_RE.fullmatch(blob_name):
            return
        try:
            files_descriptor = self._open_files_directory()
        except ResultArtifactError:
            # Never fall back to a path-based unlink if the managed directory
            # cannot be opened without following links.
            return
        try:
            os.unlink(blob_name, dir_fd=files_descriptor)
        except FileNotFoundError:
            pass
        except OSError:
            # Retention is best effort. Metadata still drops the artifact so a
            # failed deletion can never expose an unexpected file.
            pass
        finally:
            os.close(files_descriptor)


__all__ = [
    "ResultArtifactContent",
    "ResultArtifactError",
    "ResultArtifactStore",
]
