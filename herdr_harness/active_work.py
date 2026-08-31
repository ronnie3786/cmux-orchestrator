"""Domain constants and validation helpers for Herdr Active Work.

The Active Work store intentionally owns only durable coordination metadata.
It stores links and summaries, not Buzz or Pi transcript bodies.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
import uuid
from datetime import datetime, timezone
from typing import Any, Iterable, Mapping
from urllib.parse import urlparse


CURRENT_SCHEMA_VERSION = 3
DEFAULT_PIPELINE_ID = "pipeline_buzz_feature_work_v1"
DEFAULT_PIPELINE_SLUG = "buzz-feature-work"
DEFAULT_PIPELINE_VERSION = 1

WORK_KINDS = frozenset({"feature", "task", "idea"})
WORK_LIFECYCLES = frozenset({"active", "blocked", "done", "archived"})
STAGE_STATES = frozenset({"pending", "ready", "active", "blocked", "complete", "skipped"})
ATTENTION_STATES = frozenset({"none", "agent", "human"})
CHECKPOINT_STATES = frozenset({"none", "pending", "approved", "changes_requested"})
AGENT_LINK_STATES = frozenset({"queued", "active", "waiting", "done"})
AGENT_STATUSES = frozenset(
    {"unknown", "queued", "idle", "working", "waiting", "blocked", "done", "offline"}
)
SESSION_STATUSES = frozenset({"unknown", "queued", "running", "blocked", "completed", "failed", "ended"})
THREAD_STATUSES = frozenset({"active", "archived"})

DEFAULT_PIPELINE_STAGES = (
    {
        "id": "stage_buzz_feature_work_v1_01",
        "stage_key": "start-ticket",
        "sequence": 1,
        "phase_key": "open",
        "title": "Start Ticket",
        "skill_name": "buzz-start-ticket",
        "checkpoint_kind": "none",
    },
    {
        "id": "stage_buzz_feature_work_v1_02",
        "stage_key": "plan",
        "sequence": 2,
        "phase_key": "open",
        "title": "Plan",
        "skill_name": "buzz-plan",
        "checkpoint_kind": "human",
    },
    {
        "id": "stage_buzz_feature_work_v1_03",
        "stage_key": "implement",
        "sequence": 3,
        "phase_key": "build",
        "title": "Implement",
        "skill_name": "buzz-implement",
        "checkpoint_kind": "none",
    },
    {
        "id": "stage_buzz_feature_work_v1_04",
        "stage_key": "architect-code-review",
        "sequence": 4,
        "phase_key": "build",
        "title": "Architect Code Review",
        "skill_name": "buzz-architect-code-review",
        "checkpoint_kind": "none",
    },
    {
        "id": "stage_buzz_feature_work_v1_05",
        "stage_key": "proof",
        "sequence": 5,
        "phase_key": "prove",
        "title": "Proof",
        "skill_name": "buzz-proof",
        "checkpoint_kind": "human",
    },
    {
        "id": "stage_buzz_feature_work_v1_06",
        "stage_key": "code-review-pre-pr",
        "sequence": 6,
        "phase_key": "prove",
        "title": "Code Review Pre PR",
        "skill_name": "buzz-code-review-pre-pr",
        "checkpoint_kind": "human",
    },
    {
        "id": "stage_buzz_feature_work_v1_07",
        "stage_key": "pr",
        "sequence": 7,
        "phase_key": "ship",
        "title": "PR",
        "skill_name": "buzz-pr",
        "checkpoint_kind": "human",
    },
    {
        "id": "stage_buzz_feature_work_v1_08",
        "stage_key": "pr-triage",
        "sequence": 8,
        "phase_key": "ship",
        "title": "PR Triage",
        "skill_name": "buzz-pr-triage",
        "checkpoint_kind": "none",
    },
)

STAGE_KEYS = frozenset(stage["stage_key"] for stage in DEFAULT_PIPELINE_STAGES)

_INTERNAL_ID_RE = re.compile(r"^[a-z][a-z0-9_]{2,63}$")
_JIRA_KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]+-\d+$")
_SOURCE_RE = re.compile(r"^[a-z][a-z0-9_.-]{0,63}$")


class ActiveWorkError(ValueError):
    """Expected, HTTP-safe Active Work failure."""

    def __init__(self, message: str, *, code: str = "invalid_active_work", status: int = 400):
        super().__init__(message)
        self.code = code
        self.status = int(status)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def safe_id(prefix: str) -> str:
    if not _INTERNAL_ID_RE.fullmatch(prefix):
        raise ValueError("invalid internal ID prefix")
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


def text(
    value: Any,
    field: str,
    *,
    maximum: int,
    required: bool = False,
    strip: bool = True,
) -> str:
    if value is None and not required:
        return ""
    if not isinstance(value, str):
        raise ActiveWorkError(f"{field} must be a string")
    result = value.strip() if strip else value
    if "\x00" in result:
        raise ActiveWorkError(f"{field} contains a null byte")
    if required and not result:
        raise ActiveWorkError(f"{field} is required")
    if len(result) > maximum:
        raise ActiveWorkError(f"{field} exceeds {maximum} characters")
    return result


def choice(value: Any, field: str, allowed: Iterable[str], *, default: str | None = None) -> str:
    candidate = default if value is None else value
    if not isinstance(candidate, str) or candidate not in allowed:
        raise ActiveWorkError(f"{field} is invalid")
    return candidate


def source(value: Any) -> str:
    candidate = text(value, "source", maximum=64, required=True).lower()
    if not _SOURCE_RE.fullmatch(candidate):
        raise ActiveWorkError("source is invalid")
    return candidate


def jira_key(value: Any) -> str:
    candidate = text(value, "Jira key", maximum=64, required=True).upper()
    if not _JIRA_KEY_RE.fullmatch(candidate):
        raise ActiveWorkError("Jira key is invalid")
    return candidate


def internal_id(value: Any, field: str = "identifier") -> str:
    candidate = text(value, field, maximum=128, required=True)
    if not re.fullmatch(r"^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$", candidate):
        raise ActiveWorkError(f"{field} is invalid")
    return candidate


def external_id(value: Any, field: str = "external_id") -> str:
    return text(value, field, maximum=512, required=True)


def url(value: Any, field: str = "url", *, required: bool = False) -> str:
    candidate = text(value, field, maximum=4096, required=required)
    if not candidate:
        return ""
    try:
        parsed = urlparse(candidate)
        hostname = parsed.hostname
        parsed.port
    except ValueError as exc:
        raise ActiveWorkError(f"{field} must be an HTTPS URL") from exc
    if (
        parsed.scheme.lower() != "https"
        or not parsed.netloc
        or not hostname
        or parsed.username
        or parsed.password
    ):
        raise ActiveWorkError(f"{field} must be an HTTPS URL")
    return candidate


def link_url(value: Any, field: str = "url", *, required: bool = False) -> str:
    """Validate an HTTPS link or a private Buzz deep link.

    Buzz discussion links use ``buzz://message?...`` and stay inside the
    private desktop client. Other custom schemes are rejected.
    """

    candidate = text(value, field, maximum=4096, required=required)
    if not candidate:
        return ""
    try:
        parsed = urlparse(candidate)
        hostname = parsed.hostname
        parsed.port
    except ValueError as exc:
        raise ActiveWorkError(f"{field} is invalid") from exc
    if parsed.username or parsed.password or parsed.fragment:
        raise ActiveWorkError(f"{field} is invalid")
    if parsed.scheme.lower() == "https" and parsed.netloc and hostname:
        return candidate
    if parsed.scheme.lower() == "buzz" and parsed.netloc == "message":
        return candidate
    raise ActiveWorkError(f"{field} must be HTTPS or a buzz://message link")


def site_from_ticket(ticket: Mapping[str, Any]) -> str:
    explicit = str(ticket.get("site") or "").strip().lower()
    if explicit:
        try:
            parsed = urlparse(explicit if "://" in explicit else f"https://{explicit}")
            hostname = parsed.hostname
        except ValueError:
            hostname = None
        if hostname:
            return hostname.lower()
    candidate = str(ticket.get("url") or "")
    try:
        parsed = urlparse(candidate)
        hostname = parsed.hostname
    except ValueError:
        hostname = None
    return (hostname or "default").lower()


def timestamp(value: Any, field: str, *, required: bool = False) -> str | None:
    if value is None or value == "":
        if required:
            raise ActiveWorkError(f"{field} is required")
        return None
    candidate = text(value, field, maximum=64, required=True)
    try:
        parsed = datetime.fromisoformat(candidate.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ActiveWorkError(f"{field} must be an ISO-8601 timestamp") from exc
    if parsed.tzinfo is None:
        raise ActiveWorkError(f"{field} must include a timezone")
    normalized = parsed.astimezone(timezone.utc)
    return normalized.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def timestamp_value(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def bounded_json(
    value: Any,
    field: str,
    *,
    maximum_bytes: int = 128 * 1024,
    maximum_depth: int = 12,
) -> Any:
    if value is None:
        return {}

    def inspect(item: Any, depth: int) -> None:
        if depth > maximum_depth:
            raise ActiveWorkError(f"{field} is nested too deeply")
        if item is None or isinstance(item, (str, bool, int)):
            return
        if isinstance(item, float):
            if not math.isfinite(item):
                raise ActiveWorkError(f"{field} contains a non-finite number")
            return
        if isinstance(item, list):
            if len(item) > 1000:
                raise ActiveWorkError(f"{field} contains too many items")
            for child in item:
                inspect(child, depth + 1)
            return
        if isinstance(item, dict):
            if len(item) > 1000:
                raise ActiveWorkError(f"{field} contains too many fields")
            for key, child in item.items():
                if not isinstance(key, str) or "\x00" in key or len(key) > 256:
                    raise ActiveWorkError(f"{field} contains an invalid field name")
                inspect(child, depth + 1)
            return
        raise ActiveWorkError(f"{field} must contain JSON values only")

    inspect(value, 0)
    try:
        encoded = json.dumps(value, separators=(",", ":"), sort_keys=True, allow_nan=False)
    except (TypeError, ValueError) as exc:
        raise ActiveWorkError(f"{field} must be valid JSON") from exc
    if len(encoded.encode("utf-8")) > maximum_bytes:
        raise ActiveWorkError(f"{field} exceeds {maximum_bytes} bytes")
    return json.loads(encoded)


def json_dump(value: Any) -> str:
    return json.dumps(value if value is not None else {}, separators=(",", ":"), sort_keys=True)


def json_load(value: str | None, default: Any) -> Any:
    if not value:
        return default
    try:
        return json.loads(value)
    except (TypeError, json.JSONDecodeError):
        return default


def payload_hash(value: Mapping[str, Any]) -> str:
    normalized = bounded_json(dict(value), "ingestion payload", maximum_bytes=1024 * 1024)
    encoded = json.dumps(normalized, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def reject_unknown(payload: Mapping[str, Any], allowed: set[str] | frozenset[str], field: str) -> None:
    unknown = sorted(str(key) for key in payload if key not in allowed)
    if unknown:
        raise ActiveWorkError(f"{field} contains unsupported fields: {', '.join(unknown)}")


def require_mapping(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ActiveWorkError(f"{field} must be an object")
    return dict(value)


def require_list(value: Any, field: str, *, maximum: int = 500) -> list[Any]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise ActiveWorkError(f"{field} must be an array")
    if len(value) > maximum:
        raise ActiveWorkError(f"{field} contains more than {maximum} items")
    return list(value)
