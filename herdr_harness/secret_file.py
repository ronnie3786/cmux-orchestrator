"""Private bearer-token loading shared by Herdr command surfaces.

Secret files are opened without following a final symlink and are checked
before and after opening so a path swap cannot silently select another file.
"""

from __future__ import annotations

import os
import stat
from pathlib import Path
from typing import Any


MAX_BEARER_TOKEN_BYTES = 4096
MAX_SECRET_FILE_PATH_CHARS = 4096


class SecretFileError(ValueError):
    """A private secret or its file metadata is unsafe."""


def validate_bearer_token(
    value: Any,
    *,
    field: str,
    required: bool = False,
) -> str:
    """Return a header-safe bearer token or raise a secret-safe error."""

    if value is None or value == "":
        if required:
            raise SecretFileError(f"{field} is empty")
        return ""
    if not isinstance(value, str):
        raise SecretFileError(f"{field} must be text")
    try:
        encoded = value.encode("ascii")
    except UnicodeEncodeError as exc:
        raise SecretFileError(
            f"{field} must contain printable ASCII without whitespace"
        ) from exc
    if len(encoded) > MAX_BEARER_TOKEN_BYTES:
        raise SecretFileError(f"{field} exceeds {MAX_BEARER_TOKEN_BYTES} bytes")
    if any(byte < 0x21 or byte > 0x7E for byte in encoded):
        raise SecretFileError(
            f"{field} must contain printable ASCII without whitespace"
        )
    return value


def load_private_bearer_token_file(value: Any, *, field: str) -> str:
    """Read one owner-private token without following or racing a symlink."""

    if not isinstance(value, str) or not value or "\x00" in value:
        raise SecretFileError(f"{field} path is invalid")
    if len(value) > MAX_SECRET_FILE_PATH_CHARS:
        raise SecretFileError(f"{field} path is too long")
    path = Path(value)
    if not path.is_absolute():
        raise SecretFileError(f"{field} path must be absolute")

    try:
        before = os.lstat(path)
    except OSError as exc:
        raise SecretFileError(f"cannot inspect {field}: {exc}") from exc

    def validate_metadata(metadata: os.stat_result) -> None:
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise SecretFileError(f"{field} must be a regular file, not a symlink")
        if hasattr(os, "getuid") and metadata.st_uid != os.getuid():
            raise SecretFileError(f"{field} belongs to another user")
        if stat.S_IMODE(metadata.st_mode) & 0o077:
            raise SecretFileError(
                f"{field} must not be accessible by group or other users"
            )
        if metadata.st_size > MAX_BEARER_TOKEN_BYTES + 2:
            raise SecretFileError(
                f"{field} exceeds {MAX_BEARER_TOKEN_BYTES + 2} bytes"
            )

    validate_metadata(before)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    file_descriptor = -1
    try:
        file_descriptor = os.open(path, flags)
        after = os.fstat(file_descriptor)
        validate_metadata(after)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise SecretFileError(f"{field} changed while it was being opened")
        with os.fdopen(file_descriptor, "rb") as handle:
            file_descriptor = -1
            raw = handle.read(MAX_BEARER_TOKEN_BYTES + 3)
    except SecretFileError:
        raise
    except OSError as exc:
        raise SecretFileError(f"cannot read {field}: {exc}") from exc
    finally:
        if file_descriptor >= 0:
            os.close(file_descriptor)

    if len(raw) > MAX_BEARER_TOKEN_BYTES + 2:
        raise SecretFileError(f"{field} exceeds {MAX_BEARER_TOKEN_BYTES + 2} bytes")
    try:
        decoded = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise SecretFileError(f"{field} must contain UTF-8 text") from exc
    return validate_bearer_token(
        decoded.rstrip("\r\n"),
        field=field,
        required=True,
    )
