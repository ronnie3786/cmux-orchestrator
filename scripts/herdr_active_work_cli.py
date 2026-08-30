#!/usr/bin/env python3
"""Agent-first command line client for Herdr Active Work.

The CLI is intentionally a thin, JSON-only control surface over the Active
Work HTTP API. Jira candidates remain observational until one explicit
``connect`` command is issued. Rich observations are merge-only and retain the
server's idempotency, stale-write, and setup-before-ingestion guarantees.
"""

from __future__ import annotations

import argparse
import hmac
import ipaddress
import json
import os
import re
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence, TextIO


API_VERSION = "herdr.active-work.cli/v1"
DEFAULT_BASE_URL = "http://127.0.0.1:9092"
DEFAULT_TOKEN_FILE = "~/.config/herdr-harness/active-work-manage-token"
MAX_TOKEN_BYTES = 4096
MAX_TOKEN_FILE_PATH_CHARS = 4096
MAX_REQUEST_BYTES = 1024 * 1024
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
MAX_ERROR_BYTES = 64 * 1024

JIRA_KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]+-\d+$")
INTERNAL_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$")
ACTOR_RE = re.compile(r"^agent:[a-z][a-z0-9._-]{0,63}$")
ERROR_CODE_RE = re.compile(r"^[a-z][a-z0-9_.-]{0,127}$")

WORK_KINDS = ("feature", "task", "idea")
WORK_LIFECYCLES = ("active", "blocked", "done", "archived")
STAGE_STATES = ("active", "blocked")
ATTENTION_STATES = ("none", "agent", "human")
CHECKPOINT_STATES = ("none", "pending", "approved", "changes_requested")

_WORKFLOW_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,63}$")

_NO_PAYLOAD = object()


@dataclass
class CLIError(RuntimeError):
    """A safe, machine-readable CLI failure."""

    message: str
    code: str = "active_work_cli_error"
    exit_code: int = 2
    http_status: int | None = None
    retryable: bool = False

    def __str__(self) -> str:
        return self.message


class JSONArgumentParser(argparse.ArgumentParser):
    """Keep parse failures inside the CLI's JSON error contract."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        # In particular, never let ``--token`` abbreviate ``--token-file``.
        # The CLI intentionally has no raw-token argument because argv is
        # visible to other processes and frequently copied into agent logs.
        kwargs.setdefault("allow_abbrev", False)
        super().__init__(*args, **kwargs)

    def error(self, _message: str) -> None:
        # argparse normally reflects unknown values verbatim. Keep its details
        # out of the durable JSON error stream in case a caller accidentally
        # supplied a credential as an unsupported argument.
        raise CLIError(
            "command-line arguments are invalid; use --help for the supported syntax",
            code="invalid_arguments",
            exit_code=2,
        )


class RejectRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Never forward a bearer token through an HTTP redirect."""

    def redirect_request(
        self,
        request: Any,
        file_pointer: Any,
        code: int,
        message: str,
        headers: Any,
        new_url: str,
    ) -> None:
        raise urllib.error.HTTPError(
            request.full_url,
            code,
            "Herdr redirects are not allowed",
            headers,
            file_pointer,
        )


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _validated_token(value: Any, *, field: str) -> str:
    if not isinstance(value, str):
        raise CLIError(f"{field} must be text", code="invalid_configuration")
    if not value or len(value) > MAX_TOKEN_BYTES:
        raise CLIError(
            f"{field} must contain between 1 and {MAX_TOKEN_BYTES} printable ASCII characters",
            code="invalid_configuration",
        )
    if any(not 0x21 <= ord(character) <= 0x7E for character in value):
        raise CLIError(f"{field} must contain printable ASCII without spaces", code="invalid_configuration")
    return value


def load_token_file(value: Any) -> str:
    """Read a private token without following links or accepting unsafe modes."""

    if not isinstance(value, str) or not value.strip() or len(value) > MAX_TOKEN_FILE_PATH_CHARS:
        raise CLIError("manage token file path is invalid", code="invalid_configuration")
    path = os.path.abspath(os.path.expanduser(value))
    try:
        before = os.lstat(path)
    except OSError as exc:
        raise CLIError(
            f"cannot inspect manage token file: {exc}",
            code="manage_token_unavailable",
            exit_code=3,
        ) from exc

    def validate(metadata: os.stat_result) -> None:
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise CLIError(
                "manage token file must be a regular file, not a symlink",
                code="manage_token_unsafe",
                exit_code=3,
            )
        if hasattr(os, "getuid") and metadata.st_uid != os.getuid():
            raise CLIError(
                "manage token file belongs to another user",
                code="manage_token_unsafe",
                exit_code=3,
            )
        if stat.S_IMODE(metadata.st_mode) & 0o077:
            raise CLIError(
                "manage token file must not be accessible by group or other users",
                code="manage_token_unsafe",
                exit_code=3,
            )
        if metadata.st_size > MAX_TOKEN_BYTES + 2:
            raise CLIError(
                "manage token file is too large",
                code="manage_token_unsafe",
                exit_code=3,
            )

    validate(before)
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        after = os.fstat(descriptor)
        validate(after)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise CLIError(
                "manage token file changed while it was being opened",
                code="manage_token_unsafe",
                exit_code=3,
            )
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            raw = handle.read(MAX_TOKEN_BYTES + 3)
    except CLIError:
        raise
    except OSError as exc:
        raise CLIError(
            f"cannot read manage token file: {exc}",
            code="manage_token_unavailable",
            exit_code=3,
        ) from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if len(raw) > MAX_TOKEN_BYTES + 2:
        raise CLIError("manage token file is too large", code="manage_token_unsafe", exit_code=3)
    try:
        decoded = raw.decode("utf-8").rstrip("\r\n")
    except UnicodeDecodeError as exc:
        raise CLIError(
            "manage token file must contain UTF-8 text",
            code="manage_token_unsafe",
            exit_code=3,
        ) from exc
    return _validated_token(decoded, field="manage token file")


def resolve_manage_token(
    *,
    token_file: str | None,
    environ: Mapping[str, str],
) -> str:
    configured_file = str(environ.get("HERDR_ACTIVE_WORK_MANAGE_TOKEN_FILE") or "")
    if token_file and configured_file:
        explicit = os.path.abspath(os.path.expanduser(token_file))
        configured = os.path.abspath(os.path.expanduser(configured_file))
        if not hmac.compare_digest(explicit, configured):
            raise CLIError(
                "multiple manage token files were configured",
                code="invalid_configuration",
            )
    selected_file = token_file or configured_file
    direct_token = str(environ.get("HERDR_ACTIVE_WORK_MANAGE_TOKEN") or "")
    if selected_file and direct_token:
        raise CLIError(
            "configure either a manage token file or HERDR_ACTIVE_WORK_MANAGE_TOKEN, not both",
            code="invalid_configuration",
        )
    if selected_file:
        return load_token_file(selected_file)
    if direct_token:
        return _validated_token(direct_token, field="HERDR_ACTIVE_WORK_MANAGE_TOKEN")
    return load_token_file(DEFAULT_TOKEN_FILE)


def validate_base_url(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise CLIError("Herdr base URL is required", code="invalid_configuration")
    try:
        parsed = urllib.parse.urlsplit(value.strip())
        hostname = parsed.hostname
        parsed.port
    except ValueError as exc:
        raise CLIError("Herdr base URL is invalid", code="invalid_configuration") from exc
    scheme = parsed.scheme.lower()
    if (
        scheme not in {"http", "https"}
        or not parsed.netloc
        or not hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        raise CLIError(
            "Herdr base URL must be an origin without embedded credentials, path, query, or fragment",
            code="invalid_configuration",
        )
    if scheme == "http" and not _is_loopback(hostname):
        raise CLIError(
            "plain HTTP is only allowed for a loopback Herdr endpoint",
            code="invalid_configuration",
        )
    return value.strip().rstrip("/")


def _is_loopback(hostname: str) -> bool:
    if hostname.casefold() == "localhost":
        return True
    try:
        return ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        return False


def validate_actor(value: Any) -> str:
    candidate = str(value or "").strip().lower()
    if not ACTOR_RE.fullmatch(candidate):
        raise CLIError(
            "actor must match agent:<slug> using lowercase letters, numbers, dots, underscores, or hyphens",
            code="invalid_actor",
        )
    return candidate


class ActiveWorkClient:
    def __init__(
        self,
        base_url: str,
        *,
        token: str,
        actor: str,
        timeout: float,
        open_url: Callable[..., Any] | None = None,
    ) -> None:
        self.base_url = validate_base_url(base_url)
        self.token = _validated_token(token, field="manage token")
        self.actor = validate_actor(actor)
        if not 0.25 <= timeout <= 120:
            raise CLIError("timeout must be between 0.25 and 120 seconds", code="invalid_arguments")
        self.timeout = timeout
        self._open_url = open_url or urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            RejectRedirectHandler(),
        ).open

    def _redact(self, value: Any) -> str:
        return str(value).replace(self.token, "[REDACTED]")

    def _redact_value(self, value: Any) -> Any:
        """Ensure a reflected manage token can never escape through CLI JSON."""

        if isinstance(value, str):
            return self._redact(value)
        if isinstance(value, list):
            return [self._redact_value(item) for item in value]
        if isinstance(value, dict):
            return {
                self._redact(key) if isinstance(key, str) else key: self._redact_value(child)
                for key, child in value.items()
            }
        return value

    def _safe_error_code(self, value: Any, *, fallback: str) -> str:
        candidate = self._redact(value)
        return candidate if ERROR_CODE_RE.fullmatch(candidate) else fallback

    def request(
        self,
        method: str,
        path: str,
        payload: Any = _NO_PAYLOAD,
        *,
        query: Mapping[str, str] | None = None,
    ) -> dict[str, Any]:
        if not path.startswith("/") or "?" in path or "#" in path:
            raise CLIError("internal request path is invalid", code="invalid_request")
        full_path = path
        if query:
            full_path = f"{path}?{urllib.parse.urlencode(query)}"
        body: bytes | None = None
        if payload is not _NO_PAYLOAD:
            try:
                body = canonical_json(payload).encode("utf-8")
            except (TypeError, ValueError) as exc:
                raise CLIError("request payload is not valid JSON", code="invalid_payload") from exc
            if len(body) > MAX_REQUEST_BYTES:
                raise CLIError(
                    f"request exceeds {MAX_REQUEST_BYTES} bytes",
                    code="request_too_large",
                    exit_code=2,
                )
        headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {self.token}",
            "User-Agent": "herdr-active-work-cli/1",
            "X-Herdr-Actor": self.actor,
        }
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            self.base_url + full_path,
            data=body,
            headers=headers,
            method=method,
        )
        try:
            with self._open_url(request, timeout=self.timeout) as response:
                status = getattr(response, "status", None)
                if status is None and callable(getattr(response, "getcode", None)):
                    status = response.getcode()
                if isinstance(status, int) and 300 <= status < 400:
                    raise CLIError(
                        "Herdr redirects are not allowed",
                        code="redirect_not_allowed",
                        exit_code=3,
                        http_status=status,
                    )
                final_url = response.geturl() if callable(getattr(response, "geturl", None)) else request.full_url
                if final_url != request.full_url:
                    raise CLIError(
                        "Herdr redirects are not allowed",
                        code="redirect_not_allowed",
                        exit_code=3,
                    )
                raw = response.read(MAX_RESPONSE_BYTES + 1)
        except CLIError:
            raise
        except urllib.error.HTTPError as exc:
            try:
                raw_error = exc.read(MAX_ERROR_BYTES + 1)
            finally:
                exc.close()
            if 300 <= exc.code < 400:
                raise CLIError(
                    "Herdr redirects are not allowed",
                    code="redirect_not_allowed",
                    exit_code=3,
                    http_status=exc.code,
                ) from exc
            code = "herdr_http_error"
            message = f"Herdr request failed with HTTP {exc.code}"
            try:
                parsed_error = json.loads(raw_error[:MAX_ERROR_BYTES].decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                parsed_error = None
            if isinstance(parsed_error, Mapping) and isinstance(parsed_error.get("error"), Mapping):
                error = parsed_error["error"]
                if isinstance(error.get("code"), str) and error["code"]:
                    code = self._safe_error_code(error["code"][:128], fallback="herdr_http_error")
                if isinstance(error.get("message"), str) and error["message"]:
                    message = error["message"][:2048]
            raise CLIError(
                self._redact(message),
                code=code,
                exit_code=_http_exit_code(exc.code),
                http_status=exc.code,
                retryable=exc.code in {408, 425, 429} or exc.code >= 500,
            ) from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise CLIError(
                self._redact(f"cannot reach Herdr: {exc}"),
                code="herdr_unavailable",
                exit_code=3,
                retryable=True,
            ) from exc
        if len(raw) > MAX_RESPONSE_BYTES:
            raise CLIError(
                "Herdr response exceeded the safety limit",
                code="response_too_large",
                exit_code=3,
            )
        try:
            value = json.loads(raw.decode("utf-8")) if raw else {}
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise CLIError(
                "Herdr returned invalid JSON",
                code="invalid_response",
                exit_code=3,
            ) from exc
        if not isinstance(value, dict):
            raise CLIError(
                "Herdr returned a non-object JSON response",
                code="invalid_response",
                exit_code=3,
            )
        if value.get("ok") is False:
            error = value.get("error") if isinstance(value.get("error"), Mapping) else {}
            raise CLIError(
                self._redact(str(error.get("message") or "Herdr returned ok=false")[:2048]),
                code=self._safe_error_code(error.get("code"), fallback="herdr_api_error"),
                exit_code=3,
            )
        if value.get("ok") is not True:
            raise CLIError(
                "Herdr response is missing ok=true",
                code="invalid_response",
                exit_code=3,
            )
        return self._redact_value(value)


def _http_exit_code(status: int) -> int:
    if status == 404:
        return 4
    if status == 409:
        return 5
    if status in {400, 405, 413, 422}:
        return 2
    return 3


def jira_key(value: Any) -> str:
    candidate = str(value or "").strip().upper()
    if not JIRA_KEY_RE.fullmatch(candidate):
        raise CLIError("Jira key is invalid", code="invalid_jira_key")
    return candidate


def internal_id(value: Any, *, field: str = "work item reference") -> str:
    candidate = str(value or "").strip()
    if not INTERNAL_ID_RE.fullmatch(candidate):
        raise CLIError(f"{field} is invalid", code="invalid_work_item_reference")
    return candidate


def positive_revision(value: Any) -> int:
    if isinstance(value, bool):
        raise argparse.ArgumentTypeError("revision must be a positive integer")
    try:
        revision = int(value)
    except (TypeError, ValueError) as exc:
        raise argparse.ArgumentTypeError("revision must be a positive integer") from exc
    if revision < 1:
        raise argparse.ArgumentTypeError("revision must be a positive integer")
    return revision


def positive_timeout(value: Any) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise argparse.ArgumentTypeError("timeout must be a number") from exc
    if not 0.25 <= result <= 120:
        raise argparse.ArgumentTypeError("timeout must be between 0.25 and 120 seconds")
    return result


def json_object(value: str, *, field: str, maximum_bytes: int = 128 * 1024) -> dict[str, Any]:
    if len(value.encode("utf-8")) > maximum_bytes:
        raise CLIError(f"{field} is too large", code="invalid_payload")
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise CLIError(f"{field} must be valid JSON: {exc.msg}", code="invalid_payload") from exc
    if not isinstance(parsed, dict):
        raise CLIError(f"{field} must be a JSON object", code="invalid_payload")
    return parsed


def _parser(environ: Mapping[str, str]) -> JSONArgumentParser:
    parser = JSONArgumentParser(
        description=(
            "Manage Herdr Active Work with a machine-readable CLI. "
            "Use workflow-show SLUG to discover a workflow's valid stage keys."
        )
    )
    parser.add_argument(
        "--base-url",
        default=environ.get("HERDR_ACTIVE_WORK_BASE_URL") or DEFAULT_BASE_URL,
        help="Herdr origin (env: HERDR_ACTIVE_WORK_BASE_URL)",
    )
    parser.add_argument(
        "--token-file",
        help="Private manage token file (env: HERDR_ACTIVE_WORK_MANAGE_TOKEN_FILE)",
    )
    parser.add_argument(
        "--actor",
        default=environ.get("HERDR_ACTIVE_WORK_ACTOR") or "agent:herdr-active-work-cli",
        help="Audit actor in agent:<slug> form (env: HERDR_ACTIVE_WORK_ACTOR)",
    )
    parser.add_argument(
        "--timeout",
        type=positive_timeout,
        default=environ.get("HERDR_ACTIVE_WORK_TIMEOUT") or "20",
        help="Per-request timeout in seconds (env: HERDR_ACTIVE_WORK_TIMEOUT)",
    )
    parser.add_argument("--pretty", action="store_true", help="Indent the JSON response")
    parser.add_argument("--version", action="version", version="herdr-active-work 2")
    commands = parser.add_subparsers(dest="command", required=True)

    candidates = commands.add_parser("candidates", help="List observed Jira setup candidates")
    candidates.add_argument("--all", action="store_true", help="Include candidates already connected")

    list_command = commands.add_parser("list", help="List durable Active Work items")
    list_command.add_argument("--full", action="store_true", help="Return the full board projection")

    show = commands.add_parser("show", help="Show one item by work ID or Jira key")
    show.add_argument("reference")

    connect = commands.add_parser("connect", help="Explicitly connect one Jira ticket")
    connect.add_argument("jira_key")

    create = commands.add_parser("create", help="Create a Feature, Task, or Idea")
    create.add_argument("--id", dest="item_id")
    create.add_argument("--kind", choices=WORK_KINDS, default="task")
    create.add_argument("--title", required=True)
    create.add_argument("--summary")
    create.add_argument("--lifecycle", choices=WORK_LIFECYCLES)
    create.add_argument("--current-stage")
    create.add_argument("--workflow")
    create.add_argument("--next-action")
    create.add_argument("--metadata-json")

    update = commands.add_parser("update", help="Patch mutable work item fields")
    update.add_argument("reference")
    update.add_argument("--title")
    update.add_argument("--summary")
    update.add_argument("--kind", choices=WORK_KINDS)
    update.add_argument("--lifecycle", choices=WORK_LIFECYCLES)
    update.add_argument("--next-action")
    update.add_argument("--metadata-json")
    update.add_argument("--expected-revision", type=positive_revision)

    move = commands.add_parser("move", help="Move an item forward in its pipeline")
    move.add_argument("reference")
    move.add_argument("--to", required=True, dest="to_stage")
    move.add_argument("--state", choices=STAGE_STATES)
    move.add_argument("--attention", choices=ATTENTION_STATES)
    move.add_argument("--checkpoint", choices=CHECKPOINT_STATES)
    move.add_argument("--note")
    move.add_argument("--expected-revision", type=positive_revision)

    observe = commands.add_parser("observe", help="Merge an idempotent observation into existing work")
    observe.add_argument("--file", required=True, help="Ingestion JSON path, or - for stdin")

    workflow_list = commands.add_parser("workflow-list", help="List stored workflow templates")

    workflow_show = commands.add_parser(
        "workflow-show", help="Show one workflow's phases, stages, and next"
    )
    workflow_show.add_argument("slug")
    workflow_show.add_argument("--wf-version", type=int, dest="wf_version")

    workflow_apply = commands.add_parser(
        "workflow-apply", help="Validate and apply one workflow config"
    )
    workflow_apply.add_argument("--file", required=True, help="Workflow config JSON path, or - for stdin")
    workflow_apply.add_argument(
        "--validate", action="store_true", help="Validate locally only; do not contact Herdr"
    )

    stage_set = commands.add_parser("stage-set", help="Patch one stage's summary and/or content")
    stage_set.add_argument("reference")
    stage_set.add_argument("--stage", required=True, dest="stage_key")
    stage_set.add_argument("--summary")
    stage_set.add_argument(
        "--content-file", help="JSON object file to deep-merge into stage content, or - for stdin"
    )

    attach_doc = commands.add_parser("attach-doc", help="Attach or update one stage document")
    attach_doc.add_argument("reference")
    attach_doc.add_argument("--stage", required=True, dest="stage_key")
    attach_doc.add_argument("--id", required=True, dest="doc_id")
    attach_doc.add_argument("--title", required=True)
    attach_doc.add_argument("--kind", required=True, choices=("html", "json", "md", "other"))
    attach_doc.add_argument("--skill", required=True)
    attach_doc.add_argument(
        "--status",
        required=True,
        choices=("approved", "changes_requested", "awaiting-you", "info"),
    )
    attach_doc.add_argument("--by")
    attach_doc.add_argument("--url")
    attach_doc.add_argument("--at")
    return parser


def _board(client: ActiveWorkClient) -> dict[str, Any]:
    response = client.request("GET", "/api/v1/active-work")
    if (
        not isinstance(response.get("items"), list)
        or not isinstance(response.get("jira_candidates"), list)
        or not isinstance(response.get("pipeline"), Mapping)
        or not isinstance(response.get("jira_candidates_status"), Mapping)
    ):
        raise CLIError(
            "Herdr board response is missing required fields",
            code="invalid_response",
            exit_code=3,
        )
    return response


def _response_item(response: Mapping[str, Any]) -> dict[str, Any]:
    item = response.get("item")
    if not isinstance(item, dict):
        raise CLIError("Herdr response is missing an item", code="invalid_response", exit_code=3)
    return item


def resolve_reference(client: ActiveWorkClient, value: Any) -> str:
    candidate = str(value or "").strip()
    upper = candidate.upper()
    if not JIRA_KEY_RE.fullmatch(upper):
        return internal_id(candidate)
    board = _board(client)
    items = board.get("items") if isinstance(board.get("items"), list) else []
    matches: list[str] = []
    for item in items:
        if not isinstance(item, Mapping):
            continue
        links = item.get("jira_links") if isinstance(item.get("jira_links"), list) else []
        if any(
            isinstance(link, Mapping)
            and str(link.get("issue_key") or link.get("key") or "").upper() == upper
            for link in links
        ):
            identifier = item.get("id")
            if isinstance(identifier, str) and INTERNAL_ID_RE.fullmatch(identifier):
                matches.append(identifier)
    unique_matches = list(dict.fromkeys(matches))
    if not unique_matches:
        raise CLIError(
            f"{upper} is not connected to Active Work; run `herdr-active-work connect {upper}` first",
            code="active_work_not_connected",
            exit_code=4,
            http_status=404,
        )
    if len(unique_matches) > 1:
        raise CLIError(
            f"{upper} resolves to more than one Active Work item",
            code="active_work_selector_ambiguous",
            exit_code=5,
            http_status=409,
        )
    return unique_matches[0]


def _detail(client: ActiveWorkClient, item_id: str) -> dict[str, Any]:
    safe_id = urllib.parse.quote(internal_id(item_id, field="work item ID"), safe="")
    return _response_item(client.request("GET", f"/api/v1/active-work/items/{safe_id}"))


def _revision(client: ActiveWorkClient, item_id: str, explicit: int | None) -> int:
    if explicit is not None:
        return explicit
    raw = _detail(client, item_id).get("revision")
    if isinstance(raw, bool):
        raw = None
    try:
        revision = int(raw)
    except (TypeError, ValueError) as exc:
        raise CLIError(
            "Herdr item is missing a valid revision",
            code="invalid_response",
            exit_code=3,
        ) from exc
    if revision < 1:
        raise CLIError("Herdr item revision is invalid", code="invalid_response", exit_code=3)
    return revision


def _slim_item(item: Mapping[str, Any]) -> dict[str, Any]:
    links = item.get("jira_links") if isinstance(item.get("jira_links"), list) else []
    jira_keys = [
        str(link.get("issue_key") or link.get("key"))
        for link in links
        if isinstance(link, Mapping) and (link.get("issue_key") or link.get("key"))
    ]
    return {
        "id": item.get("id"),
        "jira_keys": jira_keys,
        "kind": item.get("kind"),
        "title": item.get("title"),
        "lifecycle": item.get("lifecycle"),
        "current_stage_key": item.get("current_stage_key"),
        "revision": item.get("revision"),
        "setup_state": item.get("setup_state"),
        "needs_attention": item.get("needs_attention"),
        "attention_reason": item.get("attention_reason"),
        "next_action": item.get("next_action"),
        "updated_at": item.get("updated_at"),
    }


def _read_observation(path_value: str, stdin: TextIO) -> dict[str, Any]:
    if path_value == "-":
        stream = getattr(stdin, "buffer", stdin)
        raw_value = stream.read(MAX_REQUEST_BYTES + 1)
        raw = raw_value.encode("utf-8") if isinstance(raw_value, str) else raw_value
    else:
        path = Path(os.path.abspath(os.path.expanduser(path_value)))
        try:
            before = os.lstat(path)
            if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
                raise CLIError("observation file must be a regular file", code="invalid_payload")
            if before.st_size > MAX_REQUEST_BYTES:
                raise CLIError("observation file is too large", code="request_too_large")
            descriptor = os.open(
                path,
                os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            )
            try:
                after = os.fstat(descriptor)
                if (
                    not stat.S_ISREG(after.st_mode)
                    or (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)
                ):
                    raise CLIError(
                        "observation file changed while it was being opened",
                        code="invalid_payload",
                    )
                with os.fdopen(descriptor, "rb") as handle:
                    descriptor = -1
                    raw = handle.read(MAX_REQUEST_BYTES + 1)
            finally:
                if descriptor >= 0:
                    os.close(descriptor)
        except CLIError:
            raise
        except OSError as exc:
            raise CLIError(f"cannot read observation file: {exc}", code="invalid_payload") from exc
    if len(raw) > MAX_REQUEST_BYTES:
        raise CLIError("observation JSON is too large", code="request_too_large")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CLIError("observation file must contain valid UTF-8 JSON", code="invalid_payload") from exc
    if not isinstance(value, dict):
        raise CLIError("observation must be a JSON object", code="invalid_payload")
    for field in ("source", "idempotency_key", "observed_at"):
        if not isinstance(value.get(field), str) or not value[field].strip():
            raise CLIError(f"observation {field} is required", code="invalid_payload")
    if not isinstance(value.get("selector"), dict) or not value["selector"]:
        raise CLIError("observation selector must be a non-empty object", code="invalid_payload")
    return value


def _read_json_file(path_value: str, stdin: TextIO) -> Any:
    """Read one bounded JSON value from stdin or a safely opened regular file."""

    if path_value == "-":
        stream = getattr(stdin, "buffer", stdin)
        raw_value = stream.read(MAX_REQUEST_BYTES + 1)
        raw = raw_value.encode("utf-8") if isinstance(raw_value, str) else raw_value
    else:
        path = Path(os.path.abspath(os.path.expanduser(path_value)))
        try:
            before = os.lstat(path)
            if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
                raise CLIError("JSON file must be a regular file", code="invalid_payload")
            if before.st_size > MAX_REQUEST_BYTES:
                raise CLIError("JSON file is too large", code="request_too_large")
            descriptor = os.open(
                path,
                os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            )
            try:
                after = os.fstat(descriptor)
                if (
                    not stat.S_ISREG(after.st_mode)
                    or (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)
                ):
                    raise CLIError(
                        "JSON file changed while it was being opened",
                        code="invalid_payload",
                    )
                with os.fdopen(descriptor, "rb") as handle:
                    descriptor = -1
                    raw = handle.read(MAX_REQUEST_BYTES + 1)
            finally:
                if descriptor >= 0:
                    os.close(descriptor)
        except CLIError:
            raise
        except OSError as exc:
            raise CLIError(f"cannot read JSON file: {exc}", code="invalid_payload") from exc
    if len(raw) > MAX_REQUEST_BYTES:
        raise CLIError("JSON is too large", code="request_too_large")
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CLIError("JSON file must contain valid UTF-8 JSON", code="invalid_payload") from exc


def _validate_workflow_config_minimal(payload: Any) -> None:
    if not isinstance(payload, dict):
        raise CLIError("workflow config must be a JSON object", code="workflow_config_invalid")
    for field in ("workflow", "version", "title", "phases", "stages"):
        if field not in payload:
            raise CLIError(f"workflow config is missing {field}", code="workflow_config_invalid")
    slug = payload.get("workflow")
    if not isinstance(slug, str) or not _WORKFLOW_SLUG_RE.fullmatch(slug):
        raise CLIError("workflow slug is invalid", code="workflow_config_invalid")
    stages = payload.get("stages")
    if not isinstance(stages, list) or len(stages) < 2:
        raise CLIError("workflow config needs at least 2 stages", code="workflow_config_invalid")
    keys: list[str] = []
    for stage in stages:
        if not isinstance(stage, dict) or not isinstance(stage.get("key"), str):
            raise CLIError("each stage needs a string key", code="workflow_config_invalid")
        keys.append(stage["key"])
    index_by_key = {key: index for index, key in enumerate(keys)}
    for index, stage in enumerate(stages):
        next_values = stage.get("next")
        if next_values is None:
            continue
        if not isinstance(next_values, list):
            raise CLIError("stage next must be an array", code="workflow_config_invalid")
        for next_key in next_values:
            if not isinstance(next_key, str) or index_by_key.get(next_key, -1) <= index:
                raise CLIError(
                    "stage next must reference a later stage", code="workflow_config_invalid"
                )


def execute(args: argparse.Namespace, client: ActiveWorkClient, *, stdin: TextIO) -> dict[str, Any]:
    if args.command == "candidates":
        board = _board(client)
        status = board.get("jira_candidates_status")
        if isinstance(status, Mapping) and status.get("ok") is False:
            message = status.get("error")
            raise CLIError(
                client._redact(str(message or "Jira candidates are unavailable")[:2048]),
                code="jira_candidates_unavailable",
                exit_code=3,
                retryable=True,
            )
        raw_items = board.get("jira_candidates") if isinstance(board.get("jira_candidates"), list) else []
        items = [item for item in raw_items if isinstance(item, dict)]
        if not args.all:
            items = [item for item in items if item.get("setup_state") == "available"]
        return {
            "count": len(items),
            "items": items,
            "jira_candidates_status": board.get("jira_candidates_status"),
        }

    if args.command == "list":
        board = _board(client)
        if args.full:
            return {"board": board}
        raw_items = board.get("items") if isinstance(board.get("items"), list) else []
        items = [_slim_item(item) for item in raw_items if isinstance(item, Mapping)]
        return {
            "count": len(items),
            "items": items,
            "pipeline": board.get("pipeline"),
            "jira_candidates_status": board.get("jira_candidates_status"),
        }

    if args.command == "show":
        item_id = resolve_reference(client, args.reference)
        return {"item": _detail(client, item_id)}

    if args.command == "workflow-list":
        response = client.request("GET", "/api/v1/active-work/workflows")
        workflows = response.get("workflows") if isinstance(response.get("workflows"), list) else []
        return {"count": len(workflows), "workflows": workflows}

    if args.command == "workflow-show":
        slug = str(args.slug or "").strip().lower()
        if not slug:
            raise CLIError("workflow slug is required", code="invalid_arguments")
        query = {"version": str(args.wf_version)} if args.wf_version is not None else None
        response = client.request(
            "GET",
            f"/api/v1/active-work/workflows/{urllib.parse.quote(slug, safe='')}",
            query=query,
        )
        workflow = response.get("workflow")
        if not isinstance(workflow, dict):
            raise CLIError(
                "Herdr response is missing a workflow",
                code="invalid_response",
                exit_code=3,
            )
        return {"workflow": workflow}

    if args.command == "workflow-apply":
        payload = _read_json_file(args.file, stdin)
        _validate_workflow_config_minimal(payload)
        if args.validate:
            return {
                "valid": True,
                "workflow": payload.get("workflow"),
                "version": payload.get("version"),
            }
        response = client.request("POST", "/api/v1/active-work/workflows", payload)
        workflow = response.get("workflow")
        if not isinstance(workflow, dict):
            raise CLIError(
                "Herdr response is missing a workflow",
                code="invalid_response",
                exit_code=3,
            )
        return {
            "applied": response.get("applied"),
            "reason": response.get("reason"),
            "workflow": workflow,
        }

    if args.command == "connect":
        key = jira_key(args.jira_key)
        response = client.request(
            "POST",
            f"/api/v1/active-work/jira/{urllib.parse.quote(key, safe='')}/setup",
        )
        item = _response_item(response)
        if not isinstance(response.get("created"), bool):
            raise CLIError(
                "Herdr Jira setup response is missing created state",
                code="invalid_response",
                exit_code=3,
            )
        created = response["created"]
        return {
            "created": created,
            "outcome": "created" if created else "refreshed",
            "item": item,
        }

    if args.command == "create":
        payload: dict[str, Any] = {"kind": args.kind, "title": args.title}
        if args.item_id is not None:
            payload["id"] = internal_id(args.item_id, field="work item ID")
        for option, field in (
            (args.summary, "summary"),
            (args.lifecycle, "lifecycle"),
            (args.current_stage, "current_stage_key"),
            (args.workflow, "workflow"),
            (args.next_action, "next_action"),
        ):
            if option is not None:
                payload[field] = option
        if args.metadata_json is not None:
            payload["metadata"] = json_object(args.metadata_json, field="metadata")
        return {"item": _response_item(client.request("POST", "/api/v1/active-work/items", payload))}

    if args.command == "update":
        item_id = resolve_reference(client, args.reference)
        payload = {}
        for option, field in (
            (args.title, "title"),
            (args.summary, "summary"),
            (args.kind, "kind"),
            (args.lifecycle, "lifecycle"),
            (args.next_action, "next_action"),
        ):
            if option is not None:
                payload[field] = option
        if args.metadata_json is not None:
            payload["metadata"] = json_object(args.metadata_json, field="metadata")
        if not payload:
            raise CLIError("update requires at least one field", code="invalid_arguments")
        payload["expected_revision"] = _revision(client, item_id, args.expected_revision)
        safe_id = urllib.parse.quote(item_id, safe="")
        return {
            "item": _response_item(
                client.request("PATCH", f"/api/v1/active-work/items/{safe_id}", payload)
            )
        }

    if args.command == "move":
        item_id = resolve_reference(client, args.reference)
        payload = {
            "to_stage_key": args.to_stage,
            "expected_revision": _revision(client, item_id, args.expected_revision),
        }
        for option, field in (
            (args.state, "state"),
            (args.attention, "attention"),
            (args.checkpoint, "checkpoint_state"),
            (args.note, "note"),
        ):
            if option is not None:
                payload[field] = option
        safe_id = urllib.parse.quote(item_id, safe="")
        return {
            "item": _response_item(
                client.request(
                    "POST",
                    f"/api/v1/active-work/items/{safe_id}/transitions",
                    payload,
                )
            )
        }

    if args.command == "observe":
        payload = _read_observation(args.file, stdin)
        response = client.request("POST", "/api/v1/active-work/ingestions", payload)
        for field in ("applied", "replayed", "stale"):
            if not isinstance(response.get(field), bool):
                raise CLIError(
                    f"Herdr ingestion response is missing boolean {field}",
                    code="invalid_response",
                    exit_code=3,
                )
        receipt_id = response.get("receipt_id")
        if not isinstance(receipt_id, str) or not receipt_id:
            raise CLIError(
                "Herdr ingestion response is missing a receipt ID",
                code="invalid_response",
                exit_code=3,
            )
        item_projection = response.get("item")
        if not isinstance(item_projection, dict):
            raise CLIError(
                "Herdr ingestion response is missing an item",
                code="invalid_response",
                exit_code=3,
            )
        return {
            "applied": response["applied"],
            "replayed": response["replayed"],
            "stale": response["stale"],
            "receipt_id": receipt_id,
            "item": item_projection,
        }

    if args.command == "stage-set":
        item_id = resolve_reference(client, args.reference)
        payload = {}
        if args.summary is not None:
            payload["summary"] = args.summary
        if args.content_file is not None:
            content = _read_json_file(args.content_file, stdin)
            if not isinstance(content, dict):
                raise CLIError("content file must contain a JSON object", code="invalid_payload")
            payload["content"] = content
        if not payload:
            raise CLIError(
                "stage-set requires --summary or --content-file",
                code="invalid_arguments",
            )
        stage_key = internal_id(args.stage_key, field="stage key")
        safe_item = urllib.parse.quote(item_id, safe="")
        safe_stage = urllib.parse.quote(stage_key, safe="")
        return {
            "item": _response_item(
                client.request(
                    "PATCH",
                    f"/api/v1/active-work/items/{safe_item}/stages/{safe_stage}",
                    payload,
                )
            )
        }

    if args.command == "attach-doc":
        item_id = resolve_reference(client, args.reference)
        doc_id = internal_id(args.doc_id, field="document ID")
        stage_key = internal_id(args.stage_key, field="stage key")
        document: dict[str, Any] = {
            "title": args.title,
            "kind": args.kind,
            "skill": args.skill,
            "status": args.status,
            "at": args.at or _utc_now(),
        }
        if args.by is not None:
            document["by"] = args.by
        if args.url is not None:
            document["url"] = args.url
        payload = {"content": {"documents": {doc_id: document}}}
        safe_item = urllib.parse.quote(item_id, safe="")
        safe_stage = urllib.parse.quote(stage_key, safe="")
        return {
            "item": _response_item(
                client.request(
                    "PATCH",
                    f"/api/v1/active-work/items/{safe_item}/stages/{safe_stage}",
                    payload,
                )
            )
        }

    raise CLIError("unsupported command", code="invalid_arguments")


def _write_json(stream: TextIO, value: Mapping[str, Any], *, pretty: bool) -> None:
    if pretty:
        rendered = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True)
    else:
        rendered = canonical_json(value)
    stream.write(rendered + "\n")
    stream.flush()


def _success(command: str, data: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "api_version": API_VERSION,
        "ok": True,
        "command": command,
        "data": dict(data),
    }


def _failure(command: str | None, error: CLIError) -> dict[str, Any]:
    detail: dict[str, Any] = {
        "code": error.code,
        "message": error.message,
        "retryable": error.retryable,
    }
    if error.http_status is not None:
        detail["http_status"] = error.http_status
    return {
        "api_version": API_VERSION,
        "ok": False,
        "command": command,
        "error": detail,
    }


def main(
    argv: Sequence[str] | None = None,
    *,
    environ: Mapping[str, str] | None = None,
    stdin: TextIO | None = None,
    stdout: TextIO | None = None,
    stderr: TextIO | None = None,
    open_url: Callable[..., Any] | None = None,
) -> int:
    environment = os.environ if environ is None else environ
    input_stream = sys.stdin if stdin is None else stdin
    output_stream = sys.stdout if stdout is None else stdout
    error_stream = sys.stderr if stderr is None else stderr
    args: argparse.Namespace | None = None
    try:
        args = _parser(environment).parse_args(argv)
        token = resolve_manage_token(token_file=args.token_file, environ=environment)
        client = ActiveWorkClient(
            args.base_url,
            token=token,
            actor=args.actor,
            timeout=args.timeout,
            open_url=open_url,
        )
        data = execute(args, client, stdin=input_stream)
        _write_json(output_stream, _success(args.command, data), pretty=args.pretty)
        return 0
    except CLIError as exc:
        _write_json(
            error_stream,
            _failure(getattr(args, "command", None), exc),
            pretty=bool(getattr(args, "pretty", False)),
        )
        return exc.exit_code
    except KeyboardInterrupt:
        error = CLIError("operation interrupted", code="interrupted", exit_code=130)
        _write_json(
            error_stream,
            _failure(getattr(args, "command", None), error),
            pretty=bool(getattr(args, "pretty", False)),
        )
        return error.exit_code
    except Exception:
        error = CLIError(
            "Herdr Active Work CLI could not complete the command",
            code="internal_cli_error",
            exit_code=3,
        )
        _write_json(
            error_stream,
            _failure(getattr(args, "command", None), error),
            pretty=bool(getattr(args, "pretty", False)),
        )
        return error.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
