#!/usr/bin/env python3
"""Reconcile tracked Buzz workflow tickets into Herdr Active Work.

This is deliberately a one-way, one-shot importer.  Ticket directories are
only considered after Herdr says that the corresponding Jira item has already
been set up.  The importer never creates work items and never copies message
bodies, prompts, credentials, or other transcript content into Herdr.
"""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
import stat
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence


DEFAULT_WORKFLOW_ROOT = "~/Documents/Development/buzz-workflow"
DEFAULT_HERDR_BASE_URL = "http://127.0.0.1:9092"
SYNC_TARGETS_PATH = "/api/v1/active-work/sync-targets"
INGESTIONS_PATH = "/api/v1/active-work/ingestions"

SOURCE = "buzz"
SCHEMA_VERSION = 1
MAX_STATE_BYTES = 512 * 1024
MAX_CLI_OUTPUT_BYTES = 4 * 1024 * 1024
MAX_HTTP_OUTPUT_BYTES = 4 * 1024 * 1024
MAX_TICKETS = 500
MAX_MEMBERS = 200
MAX_MESSAGES = 200
MAX_THREADS = 200
MAX_ERROR_EXCERPT = 500
MAX_AUTH_TOKEN_BYTES = 4096
MAX_AUTH_TOKEN_FILE_BYTES = MAX_AUTH_TOKEN_BYTES + 2
MAX_TOKEN_FILE_PATH_CHARS = 4096
MAX_BUZZ_PRIVATE_KEY_BYTES = 4096

TICKET_RE = re.compile(r"^[A-Z][A-Z0-9_]+-\d+$")
UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    re.IGNORECASE,
)
EVENT_ID_RE = re.compile(r"^[0-9a-f]{64}$", re.IGNORECASE)
NSEC_RE = re.compile(r"^nsec1[023456789acdefghjklmnpqrstuvwxyz]{58}$", re.IGNORECASE)

STAGE_KEYS = (
    "start-ticket",
    "plan",
    "implement",
    "architect-code-review",
    "proof",
    "code-review-pre-pr",
    "pr",
    "pr-triage",
)

# Floors whose Pi panes live on another machine; their board pane ids are
# namespaced "<floor>:<pane_id>" so they can never collide with local panes.
REMOTE_FLOORS = frozenset({"devbox"})


def _aliases(*values: str) -> set[str]:
    return {value.strip().lower().replace("_", "-").replace(" ", "-") for value in values}


STAGE_ALIASES: dict[str, set[str]] = {
    "start-ticket": _aliases(
        "start-ticket",
        "start",
        "ticket-start",
        "ticket-setup",
        "setup",
        "intake",
        "created",
        "floored",
        "cast-ready",
        "buzz-start-ticket",
    ),
    "plan": _aliases(
        "plan",
        "planning",
        "planned",
        "awaiting-approval",
        "buzz-plan",
    ),
    "implement": _aliases(
        "implement",
        "implementation",
        "implementing",
        "build",
        "building",
        "buzz-implement",
    ),
    "architect-code-review": _aliases(
        "architect-code-review",
        "architect-review",
        "architecture-review",
        "agent-review",
        "built",
        "reviewing",
        "fixing",
        "buzz-architect-code-review",
    ),
    "proof": _aliases("proof", "proving", "validation-proof", "buzz-proof"),
    "code-review-pre-pr": _aliases(
        "code-review-pre-pr",
        "pre-pr",
        "pre-pr-review",
        "review-pre-pr",
        "buzz-code-review-pre-pr",
    ),
    "pr": _aliases("pr", "pull-request", "draft-pr", "open-pr", "shipped", "buzz-pr"),
    "pr-triage": _aliases(
        "pr-triage",
        "triage",
        "review-triage",
        "teardown",
        "done",
        "buzz-pr-triage",
    ),
}

FORBIDDEN_PAYLOAD_KEY = re.compile(
    r"(?:^|_)(?:auth|authorization|body|content|credential|message|nsec|password|private(?:_key)?|prompt|secret|token|transcript)(?:$|_)",
    re.IGNORECASE,
)


class SyncError(RuntimeError):
    """Expected configuration, data, Buzz, or Herdr reconciliation failure."""


class _RejectRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Never forward the scoped bearer token through an HTTP redirect."""

    def redirect_request(self, request: Any, file_pointer: Any, code: int, message: str,
                         headers: Any, new_url: str) -> None:
        raise urllib.error.HTTPError(
            request.full_url,
            code,
            "Herdr redirects are not allowed",
            headers,
            file_pointer,
        )


@dataclass(frozen=True)
class SyncTarget:
    ticket_key: str
    work_item_id: str
    title: str = ""
    kind: str = "task"
    jira_site: str = ""


@dataclass(frozen=True)
class PreparedIngestion:
    ticket_key: str
    target: SyncTarget
    payload_hash: str
    idempotency_key: str
    document: dict[str, Any]
    request: dict[str, Any]


@dataclass
class SyncSummary:
    discovered: int = 0
    tracked: int = 0
    ingested: int = 0
    unchanged: int = 0
    untracked: int = 0
    failed: int = 0

    def as_json(self, *, dry_run: bool, plans: list[dict[str, Any]], errors: list[str]) -> dict[str, Any]:
        return {
            "ok": self.failed == 0,
            "dryRun": dry_run,
            "discovered": self.discovered,
            "tracked": self.tracked,
            "ingested": self.ingested,
            "unchanged": self.unchanged,
            "untracked": self.untracked,
            "failed": self.failed,
            "plans": plans[:MAX_TICKETS],
            "errors": errors[:20],
        }


def canonical_stage(value: Any) -> str:
    """Map a known legacy stage to the exact Active Work stage key.

    Unknown values fail closed.  Guessing a stage would silently move a ticket
    to the wrong human checkpoint, which is worse than skipping one ingestion.
    """

    if not isinstance(value, str) or not value.strip():
        raise SyncError("ticket state is missing a stage")
    normalized = re.sub(r"-+", "-", value.strip().lower().replace("_", "-").replace(" ", "-"))
    for stage_key, aliases in STAGE_ALIASES.items():
        if normalized in aliases:
            return stage_key
    raise SyncError(f"unsupported Buzz workflow stage: {safe_excerpt(value)}")


def canonical_buzz_link(channel_id: str, event_id: str, root_event_id: str) -> str:
    channel = _require_uuid(channel_id, "Buzz channel ID")
    event = _require_event_id(event_id, "Buzz event ID")
    root = _require_event_id(root_event_id, "Buzz thread root ID")
    query = urllib.parse.urlencode(
        (("channel", channel), ("id", event), ("thread", root)),
        quote_via=urllib.parse.quote,
        safe="",
    )
    return f"buzz://message?{query}"


def iso_timestamp(value: Any, *, fallback_epoch: float | None = None) -> str:
    """Normalize source time without introducing a changing wall-clock value."""

    parsed: datetime | None = None
    if isinstance(value, (int, float)):
        parsed = datetime.fromtimestamp(float(value), tz=timezone.utc)
    elif isinstance(value, str) and value.strip():
        candidate = value.strip()
        try:
            parsed = datetime.fromisoformat(candidate.replace("Z", "+00:00"))
        except ValueError:
            parsed = None
        if parsed is not None and parsed.tzinfo is None:
            parsed = None
    if parsed is None and fallback_epoch is not None:
        parsed = datetime.fromtimestamp(float(fallback_epoch), tz=timezone.utc)
    if parsed is None:
        # A stable sentinel is preferable to `now`: the latter makes retrying
        # the same source snapshot conflict with its idempotency key.
        parsed = datetime(1970, 1, 1, tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def payload_hash(value: Mapping[str, Any]) -> str:
    encoded = canonical_json(value).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def canonical_json(value: Any) -> str:
    return json.dumps(value, separators=(",", ":"), sort_keys=True, ensure_ascii=False, allow_nan=False)


def safe_excerpt(value: Any, maximum: int = MAX_ERROR_EXCERPT) -> str:
    text = str(value).replace("\x00", "")
    text = re.sub(r"nsec1[023456789acdefghjklmnpqrstuvwxyz]+", "<redacted-nsec>", text, flags=re.I)
    text = re.sub(r"(?i)(bearer\s+)[^\s,;]+", r"\1<redacted>", text)
    text = re.sub(r"\b[0-9a-fA-F]{64}\b", "<redacted-hex64>", text)
    return text[:maximum] + ("..." if len(text) > maximum else "")


def _validated_auth_token(value: Any, *, field: str, required: bool) -> str:
    if value is None or value == "":
        if required:
            raise SyncError(f"{field} is empty")
        return ""
    if not isinstance(value, str):
        raise SyncError(f"{field} must be text")
    try:
        encoded = value.encode("ascii")
    except UnicodeEncodeError as exc:
        raise SyncError(f"{field} must contain printable ASCII without whitespace") from exc
    if not encoded:
        if required:
            raise SyncError(f"{field} is empty")
        return ""
    if len(encoded) > MAX_AUTH_TOKEN_BYTES:
        raise SyncError(f"{field} exceeds {MAX_AUTH_TOKEN_BYTES} bytes")
    if any(byte < 0x21 or byte > 0x7E for byte in encoded):
        raise SyncError(f"{field} must contain printable ASCII without whitespace")
    return value


def load_secret_file(value: Any, *, field: str, maximum_bytes: int) -> str:
    """Read one private secret without following or racing a symlink."""

    if not isinstance(value, str) or not value or "\x00" in value:
        raise SyncError(f"{field} path is invalid")
    if len(value) > MAX_TOKEN_FILE_PATH_CHARS:
        raise SyncError(f"{field} path is too long")
    path = Path(os.path.abspath(os.path.expanduser(value)))
    try:
        before = os.lstat(path)
    except OSError as exc:
        raise SyncError(f"cannot inspect {field}: {safe_excerpt(exc)}") from exc

    def validate_metadata(metadata: os.stat_result) -> None:
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise SyncError(f"{field} must be a regular file, not a symlink")
        if hasattr(os, "getuid") and metadata.st_uid != os.getuid():
            raise SyncError(f"{field} belongs to another user")
        if stat.S_IMODE(metadata.st_mode) & 0o077:
            raise SyncError(f"{field} must not be accessible by group or other users")
        if metadata.st_size > maximum_bytes + 2:
            raise SyncError(f"{field} exceeds {maximum_bytes + 2} bytes")

    validate_metadata(before)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    file_descriptor = -1
    try:
        file_descriptor = os.open(path, flags)
        after = os.fstat(file_descriptor)
        validate_metadata(after)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise SyncError(f"{field} changed while it was being opened")
        with os.fdopen(file_descriptor, "rb") as handle:
            file_descriptor = -1
            raw = handle.read(maximum_bytes + 3)
    except SyncError:
        raise
    except OSError as exc:
        raise SyncError(f"cannot read {field}: {safe_excerpt(exc)}") from exc
    finally:
        if file_descriptor >= 0:
            os.close(file_descriptor)
    if len(raw) > maximum_bytes + 2:
        raise SyncError(f"{field} exceeds {maximum_bytes + 2} bytes")
    try:
        decoded = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise SyncError(f"{field} must contain UTF-8 text") from exc
    secret = decoded.rstrip("\r\n")
    return _validated_auth_token(secret, field=field, required=True)


def load_auth_token_file(value: Any) -> str:
    return load_secret_file(
        value,
        field="Active Work token file",
        maximum_bytes=MAX_AUTH_TOKEN_BYTES,
    )


def load_buzz_private_key_file(value: Any) -> str:
    return load_secret_file(
        value,
        field="Buzz private key file",
        maximum_bytes=MAX_BUZZ_PRIVATE_KEY_BYTES,
    )


def resolve_auth_token(
    *,
    token_file: str | None = None,
    environ: Mapping[str, str] | None = None,
) -> str:
    """Resolve exactly one direct or file-backed credential source."""

    environment = os.environ if environ is None else environ
    environment_file = environment.get("HERDR_ACTIVE_WORK_TOKEN_FILE") or ""
    if token_file and environment_file:
        cli_path = os.path.abspath(os.path.expanduser(token_file))
        environment_path = os.path.abspath(os.path.expanduser(environment_file))
        if cli_path != environment_path:
            raise SyncError("multiple Active Work token files were configured")
    selected_file = token_file or environment_file
    direct_token = (
        environment.get("HERDR_ACTIVE_WORK_TOKEN")
        or environment.get("HERDR_HARNESS_API_TOKEN")
        or ""
    )
    if selected_file and direct_token:
        raise SyncError(
            "configure either an Active Work token file or a token environment variable, not both"
        )
    if selected_file:
        return load_auth_token_file(selected_file)
    return _validated_auth_token(
        direct_token,
        field="Active Work token environment variable",
        required=False,
    )


def resolve_buzz_private_key(
    *,
    private_key_file: str | None = None,
    environ: Mapping[str, str] | None = None,
) -> str:
    """Resolve the Buzz identity without mutating the parent environment."""

    environment = os.environ if environ is None else environ
    environment_file = environment.get("BUZZ_PRIVATE_KEY_FILE") or ""
    if private_key_file and environment_file:
        cli_path = os.path.abspath(os.path.expanduser(private_key_file))
        environment_path = os.path.abspath(os.path.expanduser(environment_file))
        if cli_path != environment_path:
            raise SyncError("multiple Buzz private key files were configured")
    selected_file = private_key_file or environment_file
    direct_key = environment.get("BUZZ_PRIVATE_KEY") or ""
    if selected_file and direct_key:
        raise SyncError(
            "configure either a Buzz private key file or BUZZ_PRIVATE_KEY, not both"
        )
    private_key = (
        load_buzz_private_key_file(selected_file)
        if selected_file
        else _validated_auth_token(
            direct_key,
            field="BUZZ_PRIVATE_KEY",
            required=True,
        )
    )
    if not (EVENT_ID_RE.fullmatch(private_key) or NSEC_RE.fullmatch(private_key)):
        raise SyncError("Buzz private key must be a 64-character hex key or an nsec")
    return private_key


def _require_ticket(value: Any, *, field: str = "ticket") -> str:
    candidate = str(value or "").strip().upper()
    if not TICKET_RE.fullmatch(candidate):
        raise SyncError(f"invalid {field}: {safe_excerpt(candidate)}")
    return candidate


def _is_jira_key(value: Any) -> bool:
    try:
        _require_ticket(value)
    except SyncError:
        return False
    return True


def _require_uuid(value: Any, field: str) -> str:
    candidate = str(value or "").strip().lower()
    if not UUID_RE.fullmatch(candidate):
        raise SyncError(f"invalid {field}")
    return candidate


def _require_event_id(value: Any, field: str) -> str:
    candidate = str(value or "").strip().lower()
    if not EVENT_ID_RE.fullmatch(candidate):
        raise SyncError(f"invalid {field}")
    return candidate


def _bounded_text(value: Any, maximum: int) -> str:
    if not isinstance(value, (str, int, float)):
        return ""
    result = str(value).strip().replace("\x00", "")
    return result[:maximum]


def _present(value: Any) -> bool:
    """Return whether an optional JSON value should survive compaction."""

    return value is not None and value != ""


def _compact(value: Mapping[str, Any]) -> dict[str, Any]:
    return {key: child for key, child in value.items() if _present(child)}


def _https_avatar(value: Any) -> str:
    candidate = _bounded_text(value, 4096)
    if not candidate:
        return ""
    try:
        parsed = urllib.parse.urlsplit(candidate)
        hostname = parsed.hostname
        parsed.port
    except ValueError:
        return ""
    if (
        parsed.scheme.lower() != "https"
        or not parsed.netloc
        or not hostname
        or parsed.username
        or parsed.password
    ):
        return ""
    # Signed query parameters can contain bearer material.  Herdr only needs a
    # stable presentation reference, never the credential-bearing query.
    return urllib.parse.urlunsplit(("https", parsed.netloc, parsed.path, "", ""))[:2048]


def load_state(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as handle:
            raw = handle.read(MAX_STATE_BYTES + 1)
    except OSError as exc:
        raise SyncError(f"cannot read {path}: {safe_excerpt(exc)}") from exc
    if len(raw) > MAX_STATE_BYTES:
        raise SyncError(f"state file exceeds {MAX_STATE_BYTES} bytes: {path}")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SyncError(f"invalid JSON in {path}: {safe_excerpt(exc)}") from exc
    if not isinstance(value, dict):
        raise SyncError(f"state file must contain an object: {path}")
    return value


def discover_state_files(root: Path, ticket: str | None = None) -> list[Path]:
    ticket_root = (root.expanduser().resolve() / "tickets").resolve()
    if not ticket_root.is_dir():
        raise SyncError(f"Buzz workflow ticket directory not found: {ticket_root}")
    if ticket:
        key = _require_ticket(ticket)
        candidates = [ticket_root / key / "state.json"]
    else:
        candidates = sorted(ticket_root.glob("*/state.json"))
    if len(candidates) > MAX_TICKETS:
        raise SyncError(f"refusing to scan more than {MAX_TICKETS} ticket states")
    result: list[Path] = []
    for candidate in candidates:
        if candidate.is_symlink() or not candidate.is_file():
            if ticket:
                raise SyncError(f"ticket state not found: {candidate}")
            continue
        resolved = candidate.resolve()
        try:
            resolved.relative_to(ticket_root)
        except ValueError as exc:
            raise SyncError(f"ticket state escapes workflow root: {candidate}") from exc
        result.append(resolved)
    if ticket and not result:
        raise SyncError(f"ticket state not found: {candidates[0]}")
    return result


class BuzzClient:
    """Small JSON-only wrapper around the existing agent-first Buzz CLI."""

    def __init__(
        self,
        binary: str = "buzz",
        *,
        timeout: float = 20.0,
        private_key: str = "",
        run: Callable[..., subprocess.CompletedProcess[bytes]] = subprocess.run,
    ) -> None:
        self.binary = binary
        self.timeout = timeout
        self._private_key = private_key
        self._run = run

    def _json(self, arguments: Sequence[str]) -> Any:
        command = [self.binary, "--format", "json", *arguments]
        child_environment = os.environ.copy()
        for unrelated_secret in (
            "HERDR_ACTIVE_WORK_TOKEN",
            "HERDR_ACTIVE_WORK_TOKEN_FILE",
            "HERDR_HARNESS_API_TOKEN",
        ):
            child_environment.pop(unrelated_secret, None)
        if self._private_key:
            child_environment["BUZZ_PRIVATE_KEY"] = self._private_key
        try:
            completed = self._run(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=self.timeout,
                check=False,
                env=child_environment,
            )
        except FileNotFoundError as exc:
            raise SyncError(f"Buzz CLI not found: {self.binary}") from exc
        except subprocess.TimeoutExpired as exc:
            raise SyncError(f"Buzz CLI timed out after {self.timeout:g}s") from exc
        stdout = completed.stdout if isinstance(completed.stdout, bytes) else str(completed.stdout or "").encode()
        stderr = completed.stderr if isinstance(completed.stderr, bytes) else str(completed.stderr or "").encode()
        if len(stdout) > MAX_CLI_OUTPUT_BYTES or len(stderr) > MAX_CLI_OUTPUT_BYTES:
            raise SyncError("Buzz CLI output exceeded the configured safety limit")
        if completed.returncode != 0:
            detail = stderr.decode("utf-8", errors="replace") or stdout.decode("utf-8", errors="replace")
            if self._private_key:
                detail = detail.replace(self._private_key, "<redacted-buzz-private-key>")
            raise SyncError(f"Buzz CLI failed ({completed.returncode}): {safe_excerpt(detail)}")
        try:
            return json.loads(stdout.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise SyncError(f"Buzz CLI returned invalid JSON: {safe_excerpt(exc)}") from exc

    def resolve_channel(self, reference: Any) -> dict[str, Any]:
        channel_id = ""
        name = ""
        if isinstance(reference, Mapping):
            channel_id = _bounded_text(
                reference.get("channel_id") or reference.get("channelId") or reference.get("id"), 64
            )
            name = _bounded_text(reference.get("name") or reference.get("channel"), 256)
        else:
            candidate = _bounded_text(reference, 256)
            if UUID_RE.fullmatch(candidate):
                channel_id = candidate
            else:
                name = candidate.lstrip("#")
        if channel_id:
            metadata = self._json(["channels", "get", "--channel", _require_uuid(channel_id, "Buzz channel ID")])
            if not isinstance(metadata, dict) or not metadata.get("channel_id"):
                raise SyncError(f"tracked Buzz channel was not found: {safe_excerpt(channel_id)}")
            resolved_name = _bounded_text(metadata.get("name"), 256)
            if resolved_name:
                matches = self._json(
                    ["channels", "search", "--query", resolved_name, "--exact", "--include-archived"]
                )
                if isinstance(matches, list):
                    enriched = [
                        item
                        for item in matches
                        if isinstance(item, dict)
                        and str(item.get("channel_id") or "").lower() == channel_id.lower()
                    ]
                    if enriched:
                        metadata = {**metadata, **enriched[0]}
            return normalize_channel(metadata)
        if not name:
            raise SyncError("ticket state does not track a Buzz channel")
        matches = self._json(["channels", "search", "--query", name, "--exact", "--include-archived"])
        if not isinstance(matches, list):
            raise SyncError("Buzz channel search returned an invalid response")
        exact = [item for item in matches if isinstance(item, dict) and str(item.get("name", "")).casefold() == name.casefold()]
        if len(exact) != 1:
            raise SyncError(f"Buzz channel name must resolve exactly once ({name!r}, found {len(exact)})")
        return normalize_channel(exact[0])

    def members(self, channel_id: str) -> tuple[list[dict[str, Any]], bool]:
        value = self._json(["channels", "members", "--channel", channel_id])
        if not isinstance(value, list):
            raise SyncError("Buzz channel members returned an invalid response")
        truncated = len(value) > MAX_MEMBERS
        raw_members = value[:MAX_MEMBERS]
        pubkeys: list[str] = []
        roles: dict[str, str] = {}
        for item in raw_members:
            if not isinstance(item, Mapping):
                continue
            pubkey = str(item.get("pubkey") or "").strip().lower()
            if not EVENT_ID_RE.fullmatch(pubkey):
                continue
            pubkeys.append(pubkey)
            roles[pubkey] = _bounded_text(item.get("role") or "member", 32).lower()
        profiles: dict[str, Mapping[str, Any]] = {}
        for start in range(0, len(pubkeys), 200):
            chunk = pubkeys[start : start + 200]
            arguments = ["users", "get"]
            for pubkey in chunk:
                arguments.extend(("--pubkey", pubkey))
            result = self._json(arguments)
            if not isinstance(result, list):
                raise SyncError("Buzz user profiles returned an invalid response")
            for profile in result:
                if not isinstance(profile, Mapping):
                    continue
                pubkey = str(profile.get("pubkey") or "").strip().lower()
                if pubkey in roles:
                    profiles[pubkey] = profile
        members: list[dict[str, Any]] = []
        for pubkey in sorted(set(pubkeys)):
            profile = profiles.get(pubkey, {})
            member: dict[str, Any] = {
                "pubkey": pubkey,
                "role": roles.get(pubkey, "member"),
                "displayName": _bounded_text(
                    profile.get("display_name") or profile.get("name"), 160
                ),
            }
            avatar = _https_avatar(profile.get("picture") or profile.get("avatar_url"))
            if avatar:
                member["avatarUrl"] = avatar
            members.append(member)
        return members, truncated

    def channel_events(self, channel_id: str) -> tuple[list[dict[str, Any]], bool]:
        value = self._json(
            ["messages", "get", "--channel", channel_id, "--limit", str(MAX_MESSAGES)]
        )
        if not isinstance(value, list):
            raise SyncError("Buzz channel messages returned an invalid response")
        truncated = len(value) >= MAX_MESSAGES
        return [item for item in value if isinstance(item, dict)], truncated


class HerdrClient:
    def __init__(
        self,
        base_url: str,
        *,
        token: str = "",
        timeout: float = 20.0,
        open_url: Callable[..., Any] | None = None,
    ) -> None:
        try:
            parsed = urllib.parse.urlsplit(base_url)
            hostname = parsed.hostname
            # Accessing port performs additional malformed-netloc validation.
            parsed.port
        except ValueError as exc:
            raise SyncError("Herdr base URL is invalid") from exc
        scheme = parsed.scheme.lower()
        if (
            scheme not in {"http", "https"}
            or not parsed.netloc
            or not hostname
            or parsed.username
            or parsed.password
            or parsed.query
            or parsed.fragment
        ):
            raise SyncError("Herdr base URL must be an HTTP(S) URL without embedded credentials")
        if scheme == "http" and not self._is_loopback_host(hostname):
            raise SyncError("Plain HTTP is only allowed for a loopback Herdr endpoint")
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout
        self._open_url = open_url or urllib.request.build_opener(_RejectRedirectHandler()).open

    @staticmethod
    def _is_loopback_host(hostname: str) -> bool:
        if hostname.casefold() == "localhost":
            return True
        try:
            return ipaddress.ip_address(hostname).is_loopback
        except ValueError:
            return False

    def request(
        self,
        method: str,
        path: str,
        payload: Mapping[str, Any] | None = None,
        *,
        idempotency_key: str = "",
    ) -> Any:
        body = canonical_json(payload).encode("utf-8") if payload is not None else None
        headers = {"Accept": "application/json", "User-Agent": "herdr-active-work-sync/1"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if idempotency_key:
            headers["Idempotency-Key"] = idempotency_key
        request = urllib.request.Request(self.base_url + path, data=body, headers=headers, method=method)
        try:
            with self._open_url(request, timeout=self.timeout) as response:
                response_code = getattr(response, "status", None)
                if response_code is None and callable(getattr(response, "getcode", None)):
                    response_code = response.getcode()
                if isinstance(response_code, int) and 300 <= response_code < 400:
                    raise SyncError("Herdr redirects are not allowed")
                final_url = response.geturl() if callable(getattr(response, "geturl", None)) else request.full_url
                if final_url != request.full_url:
                    raise SyncError("Herdr redirects are not allowed")
                raw = response.read(MAX_HTTP_OUTPUT_BYTES + 1)
        except urllib.error.HTTPError as exc:
            detail = exc.read(MAX_ERROR_EXCERPT).decode("utf-8", errors="replace")
            if 300 <= exc.code < 400:
                raise SyncError("Herdr redirects are not allowed") from exc
            raise SyncError(f"Herdr {method} {path} failed with HTTP {exc.code}: {safe_excerpt(detail)}") from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise SyncError(f"Herdr {method} {path} failed: {safe_excerpt(exc)}") from exc
        if len(raw) > MAX_HTTP_OUTPUT_BYTES:
            raise SyncError("Herdr response exceeded the configured safety limit")
        try:
            value = json.loads(raw.decode("utf-8")) if raw else {}
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise SyncError(f"Herdr {method} {path} returned invalid JSON: {safe_excerpt(exc)}") from exc
        if isinstance(value, dict) and value.get("ok") is False:
            raise SyncError(f"Herdr {method} {path} returned ok=false: {safe_excerpt(value.get('error'))}")
        return value

    def sync_targets(self) -> Any:
        return self.request("GET", SYNC_TARGETS_PATH)

    def ingest(self, prepared: PreparedIngestion) -> Any:
        return self.request(
            "POST",
            INGESTIONS_PATH,
            prepared.request,
            idempotency_key=prepared.idempotency_key,
        )


def normalize_channel(value: Mapping[str, Any]) -> dict[str, Any]:
    channel_id = _require_uuid(value.get("channel_id") or value.get("channelId"), "Buzz channel ID")
    result: dict[str, Any] = {
        "channelId": channel_id,
        "name": _bounded_text(value.get("name"), 256),
        "type": _bounded_text(value.get("channel_type") or value.get("channelType"), 32),
        "visibility": _bounded_text(value.get("visibility"), 32),
        "archived": bool(value.get("archived", False)),
    }
    about = _bounded_text(value.get("about") or value.get("description"), 1000)
    topic = _bounded_text(value.get("topic"), 500)
    purpose = _bounded_text(value.get("purpose"), 1000)
    if about:
        result["description"] = about
    if topic:
        result["topic"] = topic
    if purpose:
        result["purpose"] = purpose
    return result


def sync_target_rows(value: Any) -> Any:
    """Return the raw sync-target candidates from a sync-targets response."""

    if not isinstance(value, Mapping):
        return None
    candidates: Any = next(
        (value[key] for key in ("targets", "syncTargets", "items") if key in value),
        None,
    )
    if candidates is None and isinstance(value.get("data"), Mapping):
        data = value["data"]
        candidates = next(
            (data[key] for key in ("targets", "syncTargets", "items") if key in data),
            None,
        )
    return candidates


def parse_sync_targets(value: Any) -> dict[str, SyncTarget]:
    candidates = sync_target_rows(value)
    if not isinstance(candidates, list):
        raise SyncError("Herdr sync-targets response is missing a targets array")
    targets: dict[str, SyncTarget] = {}
    for raw in candidates:
        if not isinstance(raw, Mapping):
            continue
        identifier = _bounded_text(
            raw.get("workItemId") or raw.get("work_item_id") or raw.get("targetId") or raw.get("id"),
            128,
        )
        if not identifier:
            raise SyncError("sync target is missing a work item ID")
        jira_refs: list[tuple[Any, str]] = []
        jira = raw.get("jira")
        if isinstance(jira, list):
            for reference in jira:
                if isinstance(reference, Mapping):
                    jira_refs.append(
                        (reference.get("issue_key") or reference.get("issueKey") or reference.get("key"),
                         _bounded_text(reference.get("site"), 256))
                    )
        elif isinstance(jira, Mapping):
            jira_refs.append((jira.get("issue_key") or jira.get("issueKey") or jira.get("key"), _bounded_text(jira.get("site"), 256)))
        direct_key = (
            raw.get("ticketKey")
            or raw.get("ticket_key")
            or raw.get("externalKey")
            or raw.get("external_key")
            or raw.get("jiraKey")
        )
        if direct_key:
            jira_refs.append((direct_key, ""))
        for key_value, jira_site in jira_refs:
            try:
                key = _require_ticket(key_value, field="sync target ticket")
            except SyncError:
                continue
            if key in targets:
                raise SyncError(f"Herdr returned duplicate sync targets for {key}")
            targets[key] = SyncTarget(
                ticket_key=key,
                work_item_id=identifier,
                title=_bounded_text(raw.get("title"), 500),
                kind=normalize_kind(raw.get("kind"), default="task"),
                jira_site=jira_site,
            )
    return targets


def normalize_kind(value: Any, *, default: str = "task") -> str:
    candidate = _bounded_text(value, 32).lower().replace("_", "-")
    if not candidate:
        return default
    if candidate in {"feature", "story", "epic"}:
        return "feature"
    if candidate in {"task", "bug", "ticket", "chore"}:
        return "task"
    if candidate == "idea":
        return "idea"
    return default


def _event_thread_root(event: Mapping[str, Any]) -> str:
    root = ""
    reply = ""
    tags = event.get("tags")
    if not isinstance(tags, list):
        return ""
    for tag in tags:
        if not isinstance(tag, list) or len(tag) < 2 or tag[0] != "e":
            continue
        event_id = str(tag[1] or "").lower()
        if not EVENT_ID_RE.fullmatch(event_id):
            continue
        marker = str(tag[3] or "") if len(tag) >= 4 else ""
        if marker == "root":
            root = event_id
        elif marker == "reply":
            reply = event_id
    return root or reply


def _tracked_thread_references(state: Mapping[str, Any]) -> list[dict[str, str]]:
    containers: list[Any] = [state.get("threads"), state.get("buzz_threads")]
    buzz = state.get("buzz")
    if isinstance(buzz, Mapping):
        containers.append(buzz.get("threads"))
    result: list[dict[str, str]] = []

    def collect(value: Any, inherited_stage: str = "") -> None:
        if isinstance(value, str):
            try:
                parsed = urllib.parse.urlsplit(value)
            except ValueError:
                return
            if parsed.scheme == "buzz" and parsed.netloc == "message":
                query = urllib.parse.parse_qs(parsed.query)
                event_id = (query.get("id") or [""])[0]
                root = (query.get("thread") or [event_id])[0]
                if EVENT_ID_RE.fullmatch(event_id) and EVENT_ID_RE.fullmatch(root):
                    result.append({"eventId": event_id.lower(), "rootEventId": root.lower(), "stageKey": inherited_stage})
            elif EVENT_ID_RE.fullmatch(value):
                result.append({"eventId": value.lower(), "rootEventId": value.lower(), "stageKey": inherited_stage})
            return
        if isinstance(value, list):
            for item in value[:MAX_THREADS]:
                collect(item, inherited_stage)
            return
        if not isinstance(value, Mapping):
            return
        event_id = value.get("eventId") or value.get("event_id") or value.get("id")
        root = value.get("rootEventId") or value.get("root_event_id") or value.get("thread") or event_id
        stage_value = value.get("stageKey") or value.get("stage_key") or value.get("stage") or inherited_stage
        if event_id and root and EVENT_ID_RE.fullmatch(str(event_id)) and EVENT_ID_RE.fullmatch(str(root)):
            stage_key = canonical_stage(stage_value) if stage_value else ""
            result.append(
                {"eventId": str(event_id).lower(), "rootEventId": str(root).lower(), "stageKey": stage_key}
            )
            return
        for key, child in list(value.items())[:MAX_THREADS]:
            stage_key = inherited_stage
            try:
                stage_key = canonical_stage(key)
            except SyncError:
                pass
            collect(child, stage_key)

    for container in containers:
        collect(container)
    return result[:MAX_THREADS]


def build_threads(
    state: Mapping[str, Any],
    channel_id: str,
    events: Iterable[Mapping[str, Any]],
) -> list[dict[str, Any]]:
    by_root: dict[str, dict[str, Any]] = {}
    for reference in _tracked_thread_references(state):
        root = reference["rootEventId"]
        by_root[root] = {
            "rootEventId": root,
            "eventId": reference["eventId"],
            **({"stageKey": reference["stageKey"]} if reference.get("stageKey") else {}),
        }
    for event in events:
        event_id = str(event.get("id") or "").lower()
        if not EVENT_ID_RE.fullmatch(event_id):
            continue
        root = _event_thread_root(event)
        try:
            kind = int(event.get("kind") or 0)
        except (TypeError, ValueError):
            kind = 0
        if kind == 45001:
            root = event_id
        if not root:
            continue
        record = by_root.setdefault(root, {"rootEventId": root, "eventId": root})
        created_at = event.get("created_at")
        if isinstance(created_at, (int, float)) and created_at >= record.get("latestActivityAt", 0):
            record["latestActivityAt"] = int(created_at)
            record["eventId"] = event_id
    threads: list[dict[str, Any]] = []
    for root, record in sorted(by_root.items()):
        record["deepLink"] = canonical_buzz_link(channel_id, record["eventId"], root)
        threads.append(record)
        if len(threads) >= MAX_THREADS:
            break
    return threads


def state_channel_reference(state: Mapping[str, Any]) -> Any:
    direct = (
        state.get("buzz_channel")
        or state.get("buzzChannel")
        or state.get("channel_id")
        or state.get("channelId")
    )
    if direct:
        return direct
    buzz = state.get("buzz")
    return buzz.get("channel") if isinstance(buzz, Mapping) else None


def build_document(
    state: Mapping[str, Any],
    target: SyncTarget,
    channel: Mapping[str, Any],
    members: list[dict[str, Any]],
    members_truncated: bool,
    threads: list[dict[str, Any]],
    messages_truncated: bool,
) -> dict[str, Any]:
    stage_key = canonical_stage(state.get("stage") or state.get("phase"))
    lifecycle = normalize_lifecycle(state.get("status"), stage_key=stage_key)
    title = target.title or _bounded_text(state.get("title"), 500) or target.ticket_key
    kind = normalize_kind(state.get("kind"), default=target.kind)
    coordination: dict[str, Any] = {
        "status": _bounded_text(state.get("status"), 64),
        "humanCheckpoint": _bounded_text(state.get("human_checkpoint"), 160),
        "sourceUpdatedAt": _bounded_text(state.get("updated_at") or state.get("updated"), 64),
    }
    coordination = {key: value for key, value in coordination.items() if value}
    runtime: dict[str, Any] = {
        "floor": _bounded_text(state.get("floor"), 128),
        "workspaceId": _bounded_text(state.get("workspace_id"), 128),
        "workspace": _bounded_text(state.get("workspace"), 256),
        "tab": _bounded_text(state.get("tab"), 128),
        "rootPaneId": _bounded_text(state.get("root_pane"), 128),
    }
    runtime = {key: value for key, value in runtime.items() if value}
    primary_agent: dict[str, Any] = {
        "pubkey": _bounded_text(state.get("buzz_agent_pubkey"), 64).lower(),
        "displayName": _bounded_text(state.get("buzz_agent"), 160),
        "state": _bounded_text(state.get("buzz_agent_state"), 64),
        "stageKeys": [stage_key],
    }
    if primary_agent["pubkey"] and not EVENT_ID_RE.fullmatch(primary_agent["pubkey"]):
        primary_agent.pop("pubkey")
    primary_agent = _compact(primary_agent)

    primary_pubkey = str(primary_agent.get("pubkey") or "")
    bot_members = [member for member in members if member.get("role") == "bot"]
    if not primary_pubkey and primary_agent.get("displayName"):
        wanted_name = str(primary_agent["displayName"]).strip().casefold()
        matching_bots = [
            member
            for member in bot_members
            if str(member.get("displayName") or "").strip().casefold() == wanted_name
        ]
        if len(matching_bots) == 1:
            primary_pubkey = str(matching_bots[0].get("pubkey") or "")
    if not primary_pubkey and len(bot_members) == 1:
        primary_pubkey = str(bot_members[0].get("pubkey") or "")

    stage_agents: list[dict[str, Any]] = []
    for member in members:
        pubkey = str(member.get("pubkey") or "")
        if member.get("role") != "bot" and pubkey != primary_pubkey:
            continue
        association: dict[str, Any] = {
            "external_id": pubkey,
            "display_name": member.get("displayName") or (
                primary_agent.get("displayName") if pubkey == primary_pubkey else ""
            ),
            "kind": "agent",
            "role_label": "driver" if pubkey == primary_pubkey else member.get("role") or "agent",
            "avatar_url": member.get("avatarUrl") or "",
            "role": "driver" if pubkey == primary_pubkey else "collaborator",
            "link_state": "active",
            "metadata": {"buzz_channel_member": True},
        }
        stage_agents.append(_compact(association))
    if primary_agent and primary_pubkey and all(item["external_id"] != primary_pubkey for item in stage_agents):
        stage_agents.append(
            {
                "external_id": primary_pubkey,
                "display_name": primary_agent.get("displayName", ""),
                "kind": "agent",
                "role_label": "driver",
                "role": "driver",
                "link_state": "active",
                "metadata": {"buzz_channel_member": False},
            }
        )
    stage_agents.sort(key=lambda item: item["external_id"])

    pi_sessions: list[dict[str, Any]] = []
    if runtime:
        runtime_identity = ":".join(
            filter(
                None,
                (
                    runtime.get("workspaceId"),
                    runtime.get("workspace"),
                    runtime.get("tab"),
                    runtime.get("rootPaneId"),
                ),
            )
        )
        if runtime_identity:
            pane_id = str(runtime.get("rootPaneId") or "")
            floor = str(runtime.get("floor") or "")
            if pane_id and floor in REMOTE_FLOORS:
                pane_id = f"{floor}:{pane_id}"
            pi_sessions.append(
                {
                    "external_id": f"state:{target.ticket_key}:{runtime_identity}"[:512],
                    "title": runtime.get("floor") or runtime.get("workspace") or target.ticket_key,
                    "provider": "pi",
                    "workspace_id": runtime.get("workspaceId") or runtime.get("workspace") or "",
                    "pane_id": pane_id,
                    "metadata": {
                        key: value
                        for key, value in {
                            "workspace_label": runtime.get("workspace"),
                            "tab": runtime.get("tab"),
                            "floor": runtime.get("floor"),
                        }.items()
                        if value
                    },
                    "role": "execution",
                }
            )

    stage_map: dict[str, dict[str, Any]] = {
        stage_key: {
            "stage_key": stage_key,
            "state": (
                "complete"
                if lifecycle == "done"
                else "blocked" if lifecycle == "blocked" else "active"
            ),
            "agents": stage_agents,
            "pi_sessions": pi_sessions,
            "threads": [],
        }
    }
    unscoped_threads: list[dict[str, Any]] = []
    for thread in threads:
        thread_stage = str(thread.get("stageKey") or "")
        external_thread: dict[str, Any] = {
            "external_id": thread["rootEventId"],
            "channel_external_id": channel["channelId"],
            "url": thread["deepLink"],
            "status": "active",
            "last_activity_at": iso_timestamp(thread.get("latestActivityAt"))
            if thread.get("latestActivityAt")
            else None,
            "metadata": {
                "channel_uuid": channel["channelId"],
                "root_event_id": thread["rootEventId"],
                "event_id": thread["eventId"],
            },
        }
        external_thread = _compact(external_thread)
        if thread_stage:
            stage_map.setdefault(
                thread_stage,
                {
                    "stage_key": thread_stage,
                    "state": "complete" if STAGE_KEYS.index(thread_stage) < STAGE_KEYS.index(stage_key) else "pending",
                    "agents": [],
                    "pi_sessions": [],
                    "threads": [],
                },
            )["threads"].append(external_thread)
        else:
            unscoped_threads.append(external_thread)

    latest_epoch = max(
        (int(thread.get("latestActivityAt") or 0) for thread in threads),
        default=0,
    )
    channel_metadata = {
        "channel_uuid": channel["channelId"],
        "channel_type": channel.get("type"),
        "visibility": channel.get("visibility"),
        "members_truncated": members_truncated,
        "messages_truncated": messages_truncated,
    }
    channel_ingestion: dict[str, Any] = {
        "external_id": channel["channelId"],
        "name": channel.get("name") or "",
        "status": "archived" if channel.get("archived") else "active",
        "last_activity_at": iso_timestamp(latest_epoch) if latest_epoch else None,
        "metadata": _compact(channel_metadata),
    }
    channel_ingestion = _compact(channel_ingestion)
    item_metadata: dict[str, Any] = {
        "kind": kind,
        "ticket_key": target.ticket_key,
        "buzz_workflow": coordination,
    }
    if runtime:
        item_metadata["herdr_runtime"] = runtime
    document: dict[str, Any] = {
        "selector": {
            "work_item_id": target.work_item_id,
            "buzz_channel_id": channel["channelId"],
            **(
                {
                    "jira_key": target.ticket_key,
                    **({"jira_site": target.jira_site} if target.jira_site else {}),
                }
                if _is_jira_key(target.ticket_key)
                else {}
            ),
        },
        "item": {
            "title": title,
            "lifecycle": lifecycle,
            "metadata": item_metadata,
        },
        "current_stage_key": stage_key,
        "channel": channel_ingestion,
        "stages": sorted(stage_map.values(), key=lambda item: STAGE_KEYS.index(item["stage_key"])),
        "threads": unscoped_threads,
    }
    assert_secret_free(document)
    return document


def normalize_lifecycle(value: Any, *, stage_key: str = "") -> str:
    candidate = _bounded_text(value, 64).lower().replace("_", "-")
    if candidate in {"blocked", "waiting", "needs-input"}:
        return "blocked"
    if candidate in {"done", "complete", "completed", "merged", "shipped"}:
        # Legacy Buzz state files sometimes say status=done while their stage
        # is still built/reviewing. The ordered stage is authoritative for
        # whether the route remains active.
        if stage_key and stage_key != "pr-triage":
            return "active"
        return "done"
    if candidate in {"archived", "cancelled", "canceled"}:
        return "archived"
    return "active"


def assert_secret_free(value: Any, path: str = "payload") -> None:
    if isinstance(value, Mapping):
        for key, child in value.items():
            if FORBIDDEN_PAYLOAD_KEY.search(str(key)):
                raise SyncError(f"refusing to ingest forbidden field {path}.{key}")
            assert_secret_free(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            assert_secret_free(child, f"{path}[{index}]")


def prepare_ingestion(
    state: Mapping[str, Any],
    target: SyncTarget,
    buzz: BuzzClient,
    *,
    fallback_observed_epoch: float | None = None,
) -> PreparedIngestion:
    if _is_jira_key(target.ticket_key):
        state_key = _require_ticket(state.get("ticket") or target.ticket_key)
        if state_key != target.ticket_key:
            raise SyncError(f"state ticket {state_key} does not match sync target {target.ticket_key}")
    channel = buzz.resolve_channel(state_channel_reference(state))
    members, members_truncated = buzz.members(channel["channelId"])
    events, messages_truncated = buzz.channel_events(channel["channelId"])
    threads = build_threads(state, channel["channelId"], events)
    document = build_document(
        state,
        target,
        channel,
        members,
        members_truncated,
        threads,
        messages_truncated,
    )
    observed_at = iso_timestamp(
        state.get("updated_at") or state.get("updated"), fallback_epoch=fallback_observed_epoch
    )
    hash_input = {"source": SOURCE, "observed_at": observed_at, **document}
    digest = payload_hash(hash_input)
    key = f"{SOURCE}:{target.ticket_key}:{digest[:32]}"
    request = {
        "source": SOURCE,
        "idempotency_key": key,
        "observed_at": observed_at,
        **document,
    }
    assert_secret_free(request)
    return PreparedIngestion(target.ticket_key, target, digest, key, document, request)


def _target_for_work_item(rows: Any, work_item_id: str, directory_key: str) -> SyncTarget | None:
    """Resolve a sync target by work item ID for IDEA-keyed ticket directories."""

    if not work_item_id:
        return None
    for row in rows:
        if not isinstance(row, Mapping):
            continue
        identifier = _bounded_text(
            row.get("workItemId") or row.get("work_item_id") or row.get("targetId") or row.get("id"),
            128,
        )
        if identifier == work_item_id:
            return SyncTarget(
                ticket_key=directory_key,
                work_item_id=work_item_id,
                title=_bounded_text(row.get("title"), 500),
                kind=normalize_kind(row.get("kind"), default="task"),
            )
    return None


def run_sync(
    workflow_root: Path,
    herdr: HerdrClient,
    buzz: BuzzClient,
    *,
    ticket: str | None = None,
    dry_run: bool = False,
) -> tuple[SyncSummary, list[dict[str, Any]], list[str]]:
    files = discover_state_files(workflow_root, ticket)
    summary = SyncSummary(discovered=len(files))
    raw_targets = herdr.sync_targets()
    targets = parse_sync_targets(raw_targets)
    plans: list[dict[str, Any]] = []
    errors: list[str] = []
    for state_path in files:
        directory_name = state_path.parent.name
        target: SyncTarget | None = None
        try:
            directory_key = _require_ticket(directory_name, field="ticket directory")
        except SyncError:
            if ticket:
                raise
            directory_key = directory_name
        else:
            target = targets.get(directory_key)
        if target is None:
            # IDEA-keyed directories have no Jira link; their buzz state records
            # the Active Work item directly (active_work_id).
            try:
                state = load_state(state_path)
            except SyncError:
                state = None
            if isinstance(state, Mapping):
                target = _target_for_work_item(
                    sync_target_rows(raw_targets),
                    _bounded_text(state.get("active_work_id"), 128),
                    directory_key,
                )
        if target is None:
            summary.untracked += 1
            if not _is_jira_key(directory_name):
                errors.append(f"{directory_name}: invalid ticket directory; skipped")
            elif ticket:
                summary.failed += 1
                errors.append(
                    f"{directory_key}: not set up in Herdr; sync will not create Jira work automatically"
                )
            continue
        summary.tracked += 1
        try:
            state = load_state(state_path)
            prepared = prepare_ingestion(
                state,
                target,
                buzz,
                fallback_observed_epoch=state_path.stat().st_mtime,
            )
            scoped_threads = sum(
                len(stage.get("threads") or []) for stage in prepared.document["stages"]
            )
            plan = {
                "ticketKey": prepared.ticket_key,
                "workItemId": target.work_item_id,
                "stageKey": prepared.document["current_stage_key"],
                "channelId": prepared.document["channel"]["external_id"],
                "agentCount": sum(
                    len(stage.get("agents") or []) for stage in prepared.document["stages"]
                ),
                "threadCount": len(prepared.document["threads"]) + scoped_threads,
                "payloadHash": prepared.payload_hash,
                "idempotencyKey": prepared.idempotency_key,
            }
            if dry_run:
                plan["action"] = "would-ingest"
            else:
                response = herdr.ingest(prepared)
                if not isinstance(response, Mapping):
                    raise SyncError("Herdr ingestion returned an invalid response")
                if response.get("replayed"):
                    summary.unchanged += 1
                    plan["action"] = "replayed"
                elif response.get("stale"):
                    summary.unchanged += 1
                    plan["action"] = "stale"
                elif response.get("applied"):
                    summary.ingested += 1
                    plan["action"] = "ingested"
                else:
                    raise SyncError("Herdr ingestion was neither applied, replayed, nor stale")
            plans.append(plan)
        except SyncError as exc:
            summary.failed += 1
            errors.append(f"{directory_key}: {safe_excerpt(exc)}")
    return summary, plans, errors


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Reconcile existing Buzz workflow ticket metadata into Herdr Active Work."
    )
    parser.add_argument(
        "--workflow-root",
        default=os.environ.get("BUZZ_WORKFLOW_ROOT", DEFAULT_WORKFLOW_ROOT),
        help="Buzz workflow root (default: BUZZ_WORKFLOW_ROOT or %(default)s)",
    )
    parser.add_argument("--ticket", help="Sync one already-set-up Jira ticket key")
    parser.add_argument("--dry-run", action="store_true", help="Resolve and hash data without POSTing")
    parser.add_argument(
        "--token-file",
        help="Read the bearer token from a private file (env: HERDR_ACTIVE_WORK_TOKEN_FILE)",
    )
    parser.add_argument(
        "--buzz-private-key-file",
        help="Read BUZZ_PRIVATE_KEY from a private file for Buzz child processes (env: BUZZ_PRIVATE_KEY_FILE)",
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("HERDR_ACTIVE_WORK_BASE_URL")
        or os.environ.get("HERDR_HARNESS_URL")
        or DEFAULT_HERDR_BASE_URL,
        help="Herdr base URL (env: HERDR_ACTIVE_WORK_BASE_URL)",
    )
    parser.add_argument(
        "--buzz-cli",
        default=os.environ.get("BUZZ_CLI", "buzz"),
        help="Buzz CLI executable (env: BUZZ_CLI)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=float(os.environ.get("HERDR_ACTIVE_WORK_TIMEOUT", "20")),
        help="Per Buzz/HTTP call timeout in seconds",
    )
    args = parser.parse_args(argv)
    if not 0.25 <= args.timeout <= 120:
        parser.error("--timeout must be between 0.25 and 120 seconds")
    if args.ticket:
        try:
            args.ticket = _require_ticket(args.ticket)
        except SyncError as exc:
            parser.error(str(exc))
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        token = resolve_auth_token(token_file=args.token_file)
        buzz_private_key = resolve_buzz_private_key(
            private_key_file=args.buzz_private_key_file
        )
        herdr = HerdrClient(args.base_url, token=token, timeout=args.timeout)
        buzz = BuzzClient(
            args.buzz_cli,
            timeout=args.timeout,
            private_key=buzz_private_key,
        )
        summary, plans, errors = run_sync(
            Path(args.workflow_root),
            herdr,
            buzz,
            ticket=args.ticket,
            dry_run=args.dry_run,
        )
    except SyncError as exc:
        print(canonical_json({"ok": False, "error": safe_excerpt(exc)}), file=sys.stderr)
        return 2
    result = summary.as_json(dry_run=args.dry_run, plans=plans, errors=errors)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if summary.failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
