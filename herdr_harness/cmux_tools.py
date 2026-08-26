"""Bounded HTTP client for Herdr's trusted, local cmux tool API.

The iOS app talks only to the authenticated Herdr API.  This client keeps the
existing cmux harness as the implementation for Git, Skills, Files, Jira, and
attachment operations without forwarding Herdr credentials upstream.
"""

from __future__ import annotations

import json
import base64
import ipaddress
import os
import re
import socket
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Mapping, Optional

from . import voice


DEFAULT_BASE_URL = "http://127.0.0.1:9091"
DEFAULT_TIMEOUT_SECONDS = 15.0
GIT_TIMEOUT_SECONDS = 10.0
JIRA_TIMEOUT_SECONDS = 15.0
GENERAL_TIMEOUT_SECONDS = 15.0
ATTACHMENT_TIMEOUT_SECONDS = 60.0
VOICE_TIMEOUT_SECONDS = 90.0
MAX_TIMEOUT_SECONDS = 120.0
DEFAULT_MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024
MAX_GIT_ROOT_BYTES = 4 * 1024
_PROJECT_KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
_JIRA_KEY_RE = re.compile(r"\b[A-Z][A-Z0-9_]+-\d+\b", re.IGNORECASE)
_VOICE_FILENAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,119}\.wav$", re.IGNORECASE)
_GIT_COMMIT_RE = re.compile(r"^[0-9A-Fa-f]{4,40}$")


class CmuxToolsError(RuntimeError):
    """Expected, HTTP-safe failure from the cmux tools adapter."""

    def __init__(
        self,
        message: str,
        *,
        code: str = "cmux_tools_error",
        status: int = 502,
        upstream_status: Optional[int] = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.status = status
        self.upstream_status = upstream_status


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    """Keep request bodies and cmux identity headers on the configured origin."""

    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


_NO_REDIRECT_OPENER = urllib.request.build_opener(_RejectRedirects())


def _open_no_redirect(request: urllib.request.Request, *, timeout: float):
    return _NO_REDIRECT_OPENER.open(request, timeout=timeout)


def _invalid_response() -> None:
    raise CmuxToolsError(
        "cmux returned an invalid response",
        code="cmux_invalid_response",
        status=502,
        upstream_status=200,
    )


def _is_string(value: Any, *, allow_empty: bool = True) -> bool:
    return isinstance(value, str) and (allow_empty or bool(value))


def _is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_optional_string(payload: dict, field: str) -> bool:
    return (
        field not in payload
        or payload[field] is None
        or _is_string(payload[field])
    )


def _valid_git_file(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and _is_string(value.get("status"), allow_empty=False)
        and _is_string(value.get("file"), allow_empty=False)
    )


def _valid_git_commit(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and _is_string(value.get("hash"), allow_empty=False)
        and _is_string(value.get("message"))
    )


def _valid_git_commit_file(value: Any) -> bool:
    if not _valid_git_file(value):
        return False
    file = value["file"]
    path = Path(file)
    return (
        len(file) <= 4096
        and "\x00" not in file
        and not path.is_absolute()
        and all(part not in {"", ".", ".."} for part in path.parts)
    )


def _valid_skill(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and _is_string(value.get("name"), allow_empty=False)
        and _is_string(value.get("skillFilePath"), allow_empty=False)
        and _is_optional_string(value, "scope")
    )


def _valid_file_match(value: Any) -> bool:
    return isinstance(value, dict) and _is_string(value.get("path"), allow_empty=False)


def _valid_jira_ticket(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and _is_string(value.get("key"), allow_empty=False)
        and _is_optional_string(value, "projectKey")
        and all(
            _is_string(value.get(field))
            for field in ("title", "status", "priority", "issueType", "url")
        )
    )


def _valid_github_review_request(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and _is_integer(value.get("number"))
        and value["number"] > 0
        and _is_string(value.get("title"), allow_empty=False)
        and _is_string(value.get("url"), allow_empty=False)
        and isinstance(value.get("isDraft"), bool)
        and all(
            _is_string(value.get(field))
            for field in ("state", "owner", "repo", "author")
        )
    )


def _validate_ack(payload: dict) -> dict:
    if payload.get("ok") is not True:
        _invalid_response()
    return payload


def _validate_git_status(payload: dict) -> dict:
    if not (
        payload.get("ok") is True
        and _is_string(payload.get("cwd"), allow_empty=False)
        and _is_string(payload.get("branch"))
        and isinstance(payload.get("staged"), list)
        and all(_valid_git_file(item) for item in payload["staged"])
        and isinstance(payload.get("unstaged"), list)
        and all(_valid_git_file(item) for item in payload["unstaged"])
        and isinstance(payload.get("untracked"), list)
        and all(_is_string(item, allow_empty=False) for item in payload["untracked"])
        and isinstance(payload.get("commits"), list)
        and all(_valid_git_commit(item) for item in payload["commits"])
    ):
        _invalid_response()
    return payload


def _validate_git_diff(payload: dict) -> dict:
    if payload.get("ok") is not True or not _is_string(payload.get("diff")):
        _invalid_response()
    return payload


def _validate_git_commit_files(payload: dict) -> dict:
    files = payload.get("files")
    if not (
        payload.get("ok") is True
        and isinstance(files, list)
        and all(_valid_git_commit_file(item) for item in files)
    ):
        _invalid_response()
    return payload


def _validate_skills(payload: dict) -> dict:
    skill_fields = ("projectSkills", "userSkills", "skills")
    if not (
        payload.get("ok") is True
        and _is_optional_string(payload, "rootPath")
        and _is_optional_string(payload, "skillsDirectory")
        and _is_optional_string(payload, "userSkillsDirectory")
        and any(field in payload and isinstance(payload[field], list) for field in skill_fields)
        and all(
            field not in payload
            or (
                isinstance(payload[field], list)
                and all(_valid_skill(item) for item in payload[field])
            )
            for field in skill_fields
        )
    ):
        _invalid_response()
    return payload


def _validate_file_search(payload: dict) -> dict:
    if not (
        payload.get("ok") is True
        and _is_optional_string(payload, "rootPath")
        and _is_string(payload.get("query"))
        and isinstance(payload.get("files"), list)
        and all(_valid_file_match(item) for item in payload["files"])
        and (
            "truncated" not in payload
            or payload["truncated"] is None
            or isinstance(payload["truncated"], bool)
        )
        and (
            "limit" not in payload
            or payload["limit"] is None
            or (_is_integer(payload["limit"]) and 1 <= payload["limit"] <= 500)
        )
    ):
        _invalid_response()
    return payload


def _validate_jira_assigned(payload: dict) -> dict:
    project = payload.get("project")
    if not (
        payload.get("ok") is True
        and (project is None or _is_string(project, allow_empty=False))
        and (
            "projects" not in payload
            or payload["projects"] is None
            or (
                isinstance(payload["projects"], list)
                and all(_is_string(item, allow_empty=False) for item in payload["projects"])
            )
        )
        and _is_optional_string(payload, "site")
        and isinstance(payload.get("tickets"), list)
        and all(_valid_jira_ticket(item) for item in payload["tickets"])
    ):
        _invalid_response()
    return payload


def _validate_jira_issue(payload: dict) -> dict:
    if not (
        payload.get("ok") is True
        and _is_optional_string(payload, "site")
        and _valid_jira_ticket(payload.get("ticket"))
    ):
        _invalid_response()
    return payload


def _validate_github_review_requests(payload: dict) -> dict:
    section = payload.get("pullRequests")
    if not (
        payload.get("ok") is True
        and isinstance(section, dict)
        and isinstance(section.get("ok"), bool)
        and isinstance(section.get("items"), list)
        and all(_valid_github_review_request(item) for item in section["items"])
        and _is_optional_string(section, "error")
    ):
        _invalid_response()
    return section


def _validate_attachment(payload: dict) -> dict:
    attachment = payload.get("attachment")
    if not (
        payload.get("ok") is True
        and isinstance(attachment, dict)
        and all(
            _is_string(attachment.get(field), allow_empty=False)
            for field in (
                "id",
                "filename",
                "originalFilename",
                "contentType",
                "path",
                "workspaceKey",
                "createdAt",
            )
        )
        and _is_integer(attachment.get("size"))
        and attachment["size"] > 0
    ):
        _invalid_response()
    return payload


def _validate_transcription(payload: dict) -> dict:
    text = payload.get("text")
    backend = payload.get("backend")
    language = payload.get("language")
    if not (
        payload.get("ok") is True
        and isinstance(text, str)
        and bool(text.strip())
        and len(text) <= voice.MAX_TRANSCRIPT_CHARACTERS
        and isinstance(backend, str)
        and 0 < len(backend) <= 64
        and (language is None or (isinstance(language, str) and len(language) <= 64))
    ):
        _invalid_response()
    return payload


def _validate_status(payload: dict) -> dict:
    workspaces = payload.get("workspaces")
    if not isinstance(workspaces, list):
        _invalid_response()
    for workspace in workspaces:
        if not isinstance(workspace, dict):
            _invalid_response()
        cwd = workspace.get("cwd")
        workspace_uuid = workspace.get("uuid")
        workspace_index = workspace.get("index")
        if not (
            _is_string(cwd)
            and "\x00" not in cwd
            and len(cwd) <= 4096
            and _is_string(workspace_uuid)
            and not any(character in workspace_uuid for character in ("\x00", "\r", "\n"))
            and _is_integer(workspace_index)
            and 0 <= workspace_index <= 2**31 - 1
        ):
            _invalid_response()
    return payload


def _normalized_base_url(value: Any) -> str:
    raw = str(value or DEFAULT_BASE_URL).strip().rstrip("/")
    if raw.endswith("/harness"):
        raw = raw[: -len("/harness")]
    try:
        parsed = urllib.parse.urlsplit(raw)
        parsed_port = parsed.port
    except ValueError as exc:
        raise ValueError("cmux upstream URL is invalid") from exc
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("cmux upstream URL is invalid")
    if parsed_port is not None and not 1 <= parsed_port <= 65535:
        raise ValueError("cmux upstream URL has an invalid port")
    if parsed.netloc.startswith("["):
        try:
            ipaddress.IPv6Address(parsed.hostname or "")
        except ipaddress.AddressValueError as exc:
            raise ValueError("cmux upstream URL has an invalid IPv6 host") from exc
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("cmux upstream URL must not contain credentials")
    if parsed.query or parsed.fragment:
        raise ValueError("cmux upstream URL must not contain a query or fragment")
    base_path = parsed.path.rstrip("/")
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, base_path, "", ""))


def _clean_error(value: Any, *, fallback: str) -> str:
    if isinstance(value, dict):
        value = value.get("message") or value.get("error")
    text = str(value or "")
    text = "".join(
        character
        for character in text
        if character in "\n\t" or ord(character) >= 32
    ).strip()
    return text[:1_000] or fallback


def _root_path(root: Path | str) -> str:
    if not isinstance(root, (Path, str)):
        raise CmuxToolsError("workspace root is invalid", code="invalid_workspace_root", status=400)
    text = str(root)
    if not text or "\x00" in text or len(text) > 4096:
        raise CmuxToolsError("workspace root is invalid", code="invalid_workspace_root", status=400)
    try:
        path = Path(text).expanduser().resolve()
    except (OSError, RuntimeError, ValueError) as exc:
        raise CmuxToolsError(
            "workspace root is invalid",
            code="invalid_workspace_root",
            status=400,
        ) from exc
    if not path.is_absolute() or not path.is_dir():
        raise CmuxToolsError(
            "workspace root is unavailable",
            code="workspace_root_not_found",
            status=404,
        )
    return str(path)


def _git_root_path(root: Path | str) -> str:
    """Resolve a nested pane cwd to the checkout root used by cmux Git APIs."""

    workspace_root = _root_path(root)
    try:
        # Keep the tiny discovery result out of an unbounded subprocess pipe.
        # A pane can report any nested cwd, while cmux's path-based Git routes
        # expect repository-relative filenames rooted at the checkout.
        with tempfile.TemporaryFile(mode="w+b") as stdout_file:
            result = subprocess.run(
                ["git", "-C", workspace_root, "rev-parse", "--show-toplevel"],
                stdout=stdout_file,
                stderr=subprocess.DEVNULL,
                timeout=GIT_TIMEOUT_SECONDS,
                check=False,
            )
            stdout_file.seek(0)
            encoded = stdout_file.read(MAX_GIT_ROOT_BYTES + 1)
    except FileNotFoundError as exc:
        raise CmuxToolsError(
            "Git is unavailable on the Herdr server",
            code="git_unavailable",
            status=503,
        ) from exc
    except subprocess.TimeoutExpired as exc:
        raise CmuxToolsError(
            "Git repository discovery timed out",
            code="git_timeout",
            status=504,
        ) from exc
    except OSError as exc:
        raise CmuxToolsError(
            "Git repository discovery failed",
            code="git_failed",
            status=502,
        ) from exc

    if result.returncode != 0:
        raise CmuxToolsError(
            "Workspace is not inside a Git repository",
            code="git_repository_not_found",
            status=404,
        )
    if not encoded or len(encoded) > MAX_GIT_ROOT_BYTES:
        raise CmuxToolsError(
            "Git returned an invalid repository path",
            code="git_repository_invalid",
            status=502,
        )
    try:
        candidate = Path(encoded.decode("utf-8").strip()).expanduser().resolve()
        if (
            not candidate.is_dir()
            or os.path.commonpath((str(candidate), workspace_root)) != str(candidate)
        ):
            raise ValueError("repository root is not an ancestor of the workspace root")
    except (OSError, RuntimeError, UnicodeDecodeError, ValueError) as exc:
        raise CmuxToolsError(
            "Git returned an invalid repository path",
            code="git_repository_invalid",
            status=502,
        ) from exc
    return str(candidate)


def _relative_git_path(root: str, file: Any) -> str:
    if not isinstance(file, str) or not file or "\x00" in file or len(file) > 4096:
        raise CmuxToolsError("file is required", code="invalid_git_path", status=400)
    candidate_path = Path(file)
    if candidate_path.is_absolute() or any(
        part in {"", ".", ".."} for part in candidate_path.parts
    ):
        raise CmuxToolsError(
            "file must be a repository-relative path without traversal",
            code="invalid_git_path",
            status=400,
        )
    try:
        # Git addresses the index by repository-relative pathname. Resolve the
        # parent to catch directory symlink escapes, but allow the final inode
        # itself to be a symlink because git stages/diffs that pathname rather
        # than its target.
        parent = (Path(root) / candidate_path.parent).resolve(strict=False)
        if os.path.commonpath((root, str(parent))) != root:
            raise CmuxToolsError(
                "file must stay inside the repository",
                code="invalid_git_path",
                status=400,
            )
    except ValueError as exc:
        raise CmuxToolsError(
            "file must stay inside the repository",
            code="invalid_git_path",
            status=400,
        ) from exc
    return candidate_path.as_posix()


def _git_commit_hash(value: Any) -> str:
    if not isinstance(value, str) or not _GIT_COMMIT_RE.fullmatch(value):
        raise CmuxToolsError(
            "hash must be a 4 to 40 character hexadecimal Git commit ID",
            code="invalid_git_hash",
            status=400,
        )
    return value.lower()


def _require_expected_git_root(current_root: str, expected_root: Any) -> None:
    """Compare a client snapshot root without ever using it as a selector."""

    if (
        not isinstance(expected_root, str)
        or not expected_root
        or "\x00" in expected_root
        or len(expected_root) > 4096
        or not Path(expected_root).is_absolute()
    ):
        raise CmuxToolsError(
            "expected_root must be the absolute repository path from Git status",
            code="invalid_git_root_precondition",
            status=400,
        )
    normalized_expected = os.path.normpath(expected_root)
    if normalized_expected != current_root:
        raise CmuxToolsError(
            "This pane moved to a different Git repository. Refresh Git status before continuing.",
            code="git_repository_changed",
            status=409,
        )


class CmuxToolsClient:
    """Call the cmux harness using server-resolved roots and bounded I/O."""

    def __init__(
        self,
        environ: Optional[Mapping[str, str]] = None,
        *,
        base_url: Optional[str] = None,
        timeout: float = DEFAULT_TIMEOUT_SECONDS,
        max_response_bytes: int = DEFAULT_MAX_RESPONSE_BYTES,
    ) -> None:
        environment = os.environ if environ is None else environ
        configured = base_url or environment.get("HERDR_HARNESS_CMUX_URL") or DEFAULT_BASE_URL
        self.base_url = _normalized_base_url(configured)
        try:
            self.timeout = float(timeout)
        except (TypeError, ValueError) as exc:
            raise ValueError("timeout must be a positive number") from exc
        if not 0.1 <= self.timeout <= MAX_TIMEOUT_SECONDS:
            raise ValueError("timeout must be between 0.1 and 120 seconds")
        try:
            self.max_response_bytes = int(max_response_bytes)
        except (TypeError, ValueError) as exc:
            raise ValueError("max_response_bytes must be a positive integer") from exc
        if not 1024 <= self.max_response_bytes <= 16 * 1024 * 1024:
            raise ValueError("max_response_bytes must be between 1 KB and 16 MB")

    def _url(self, path: str, query: Optional[Mapping[str, Any]] = None) -> str:
        # Re-normalize because diagnostics and tests may intentionally replace
        # the trusted upstream at runtime.
        base = _normalized_base_url(self.base_url)
        url = f"{base}{path}"
        if query:
            url = f"{url}?{urllib.parse.urlencode(query)}"
        return url

    def _operation_timeout(self, minimum: float) -> float:
        """Honor caller configuration while retaining cmux's timeout floors."""

        return min(MAX_TIMEOUT_SECONDS, max(self.timeout, minimum))

    def _read_json(self, response: Any, *, upstream_status: int) -> dict:
        content_length = response.headers.get("Content-Length")
        if content_length:
            try:
                if int(content_length) > self.max_response_bytes:
                    raise CmuxToolsError(
                        "cmux response exceeded the size limit",
                        code="cmux_response_too_large",
                        status=502,
                        upstream_status=upstream_status,
                    )
            except ValueError:
                pass
        data = response.read(self.max_response_bytes + 1)
        if len(data) > self.max_response_bytes:
            raise CmuxToolsError(
                "cmux response exceeded the size limit",
                code="cmux_response_too_large",
                status=502,
                upstream_status=upstream_status,
            )
        try:
            payload = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise CmuxToolsError(
                "cmux returned an invalid response",
                code="cmux_invalid_response",
                status=502,
                upstream_status=upstream_status,
            ) from exc
        if not isinstance(payload, dict):
            raise CmuxToolsError(
                "cmux returned an invalid response",
                code="cmux_invalid_response",
                status=502,
                upstream_status=upstream_status,
            )
        return payload

    def _request(
        self,
        path: str,
        *,
        query: Optional[Mapping[str, Any]] = None,
        body: Optional[dict] = None,
        data: Optional[bytes] = None,
        headers: Optional[Mapping[str, str]] = None,
        timeout: Optional[float] = None,
        require_ok: bool = True,
    ) -> dict:
        if body is not None and data is not None:
            raise ValueError("body and data are mutually exclusive")
        request_headers = {"Accept": "application/json"}
        request_data = data
        if body is not None:
            request_data = json.dumps(body, separators=(",", ":")).encode("utf-8")
            request_headers["Content-Type"] = "application/json"
        if headers:
            request_headers.update(headers)
        request = urllib.request.Request(
            self._url(path, query),
            data=request_data,
            headers=request_headers,
            method="POST" if request_data is not None else "GET",
        )
        try:
            with _open_no_redirect(
                request,
                timeout=(
                    self._operation_timeout(GENERAL_TIMEOUT_SECONDS)
                    if timeout is None
                    else timeout
                ),
            ) as response:
                payload = self._read_json(
                    response,
                    upstream_status=int(getattr(response, "status", 200)),
                )
        except urllib.error.HTTPError as exc:
            if 400 <= exc.code < 500:
                try:
                    payload = self._read_json(exc, upstream_status=exc.code)
                except CmuxToolsError:
                    message = "cmux rejected the request"
                else:
                    message = _clean_error(
                        payload.get("error"),
                        fallback="cmux rejected the request",
                    )
                raise CmuxToolsError(
                    message,
                    code="cmux_upstream_error",
                    status=exc.code,
                    upstream_status=exc.code,
                ) from exc
            raise CmuxToolsError(
                "cmux could not complete the request",
                code="cmux_upstream_error",
                status=502,
                upstream_status=exc.code,
            ) from exc
        except (urllib.error.URLError, TimeoutError, socket.timeout, OSError) as exc:
            raise CmuxToolsError(
                "The cmux tools service is unavailable.",
                code="cmux_unavailable",
                status=503,
            ) from exc

        if payload.get("ok") is False:
            raise CmuxToolsError(
                _clean_error(payload.get("error"), fallback="cmux could not complete the request"),
                code="cmux_upstream_error",
                status=502,
                upstream_status=200,
            )
        if require_ok and payload.get("ok") is not True:
            _invalid_response()
        return payload

    def git_status(self, root: Path | str) -> dict:
        path = _git_root_path(root)
        payload = _validate_git_status(
            self._request(
                "/api/git-status-path",
                query={"path": path},
                timeout=self._operation_timeout(GIT_TIMEOUT_SECONDS),
            )
        )
        # The local discovery result is the canonical root used for all later
        # operations. Do not trust an upstream response to redefine it.
        payload["cwd"] = path
        return payload

    def git_diff(
        self,
        root: Path | str,
        file: Any,
        section: str,
        *,
        expected_root: Any = None,
    ) -> dict:
        path = _git_root_path(root)
        if expected_root is not None:
            _require_expected_git_root(path, expected_root)
        relative = _relative_git_path(path, file)
        if section not in {"staged", "unstaged", "untracked"}:
            raise CmuxToolsError(
                "section must be staged, unstaged, or untracked",
                code="invalid_git_section",
                status=400,
            )
        return _validate_git_diff(
            self._request(
                "/api/git-diff-path",
                body={"path": path, "file": relative, "section": section},
                timeout=self._operation_timeout(GIT_TIMEOUT_SECONDS),
            )
        )

    def git_stage(
        self,
        root: Path | str,
        file: Any,
        *,
        expected_root: Any = None,
    ) -> dict:
        path = _git_root_path(root)
        if expected_root is not None:
            _require_expected_git_root(path, expected_root)
        relative = _relative_git_path(path, file)
        payload = _validate_ack(
            self._request(
                "/api/git-stage-path",
                body={"path": path, "file": relative},
                timeout=self._operation_timeout(GIT_TIMEOUT_SECONDS),
            )
        )
        payload.setdefault("file", relative)
        return payload

    def git_unstage(
        self,
        root: Path | str,
        file: Any,
        *,
        expected_root: Any = None,
    ) -> dict:
        path = _git_root_path(root)
        if expected_root is not None:
            _require_expected_git_root(path, expected_root)
        relative = _relative_git_path(path, file)
        payload = _validate_ack(
            self._request(
                "/api/git-unstage-path",
                body={"path": path, "file": relative},
                timeout=self._operation_timeout(GIT_TIMEOUT_SECONDS),
            )
        )
        payload.setdefault("file", relative)
        return payload

    def git_commit_files(
        self,
        root: Path | str,
        commit_hash: Any,
        *,
        expected_root: Any = None,
    ) -> dict:
        path = _git_root_path(root)
        if expected_root is not None:
            _require_expected_git_root(path, expected_root)
        normalized_hash = _git_commit_hash(commit_hash)
        payload = _validate_git_commit_files(
            self._request(
                "/api/git-commit-files",
                body={"path": path, "hash": normalized_hash},
                timeout=self._operation_timeout(GIT_TIMEOUT_SECONDS),
            )
        )
        payload["hash"] = normalized_hash
        return payload

    def git_commit_diff(
        self,
        root: Path | str,
        commit_hash: Any,
        file: Any,
        *,
        expected_root: Any = None,
    ) -> dict:
        path = _git_root_path(root)
        if expected_root is not None:
            _require_expected_git_root(path, expected_root)
        normalized_hash = _git_commit_hash(commit_hash)
        relative = _relative_git_path(path, file)
        payload = _validate_git_diff(
            self._request(
                "/api/git-commit-diff",
                body={"path": path, "hash": normalized_hash, "file": relative},
                timeout=self._operation_timeout(GIT_TIMEOUT_SECONDS),
            )
        )
        payload["hash"] = normalized_hash
        payload["file"] = relative
        return payload

    def skills(self, root: Path | str) -> dict:
        return _validate_skills(
            self._request("/api/skills", query={"path": _root_path(root)})
        )

    def search_files(
        self,
        root: Path | str,
        query: str,
        limit: int = 80,
    ) -> dict:
        if not isinstance(query, str) or "\x00" in query or len(query) > 512:
            raise CmuxToolsError("query is invalid", code="invalid_file_query", status=400)
        try:
            maximum = int(limit)
        except (TypeError, ValueError) as exc:
            raise CmuxToolsError("limit is invalid", code="invalid_file_limit", status=400) from exc
        if not 1 <= maximum <= 500:
            raise CmuxToolsError("limit is invalid", code="invalid_file_limit", status=400)
        return _validate_file_search(
            self._request(
                "/api/file-search",
                query={"path": _root_path(root), "q": query, "limit": maximum},
            )
        )

    def jira_assigned(self, project: Optional[str] = None, limit: int = 50) -> dict:
        normalized_project = str(project or "").strip().upper()
        if normalized_project and not _PROJECT_KEY_RE.fullmatch(normalized_project):
            raise CmuxToolsError(
                "project is invalid",
                code="invalid_jira_project",
                status=400,
            )
        try:
            maximum = int(limit)
        except (TypeError, ValueError) as exc:
            raise CmuxToolsError("limit is invalid", code="invalid_jira_limit", status=400) from exc
        if not 1 <= maximum <= 100:
            raise CmuxToolsError("limit is invalid", code="invalid_jira_limit", status=400)
        query: dict[str, Any] = {"limit": maximum}
        if normalized_project:
            query = {"project": normalized_project, "limit": maximum}
        return _validate_jira_assigned(
            self._request(
                "/api/jira/assigned",
                query=query,
                timeout=self._operation_timeout(JIRA_TIMEOUT_SECONDS),
            )
        )

    def jira_issue(self, query: str) -> dict:
        if not isinstance(query, str) or "\x00" in query or len(query) > 2048:
            raise CmuxToolsError("Jira query is invalid", code="invalid_jira_key", status=400)
        match = _JIRA_KEY_RE.search(query)
        if match is None:
            raise CmuxToolsError(
                "A valid Jira key or URL is required",
                code="invalid_jira_key",
                status=400,
            )
        return _validate_jira_issue(
            self._request(
                "/api/jira/issue",
                query={"q": match.group(0).upper()},
                timeout=self._operation_timeout(JIRA_TIMEOUT_SECONDS),
            )
        )

    def github_review_requests(self) -> dict:
        return _validate_github_review_requests(
            self._request(
                "/api/orchestrator-v2/left-rail/review-requests",
                timeout=self._operation_timeout(30.0),
            )
        )

    def attachment_workspace_identity(self, root: Path | str) -> dict:
        """Resolve a Herdr checkout to the live cmux workspace that owns files.

        cmux reports one status entry per surface, so the same workspace UUID
        can appear more than once with virtual indices. Prefer an exact cwd
        match. If a terminal has moved below the checkout root, accept that
        descendant only when no exact match exists. A cmux cwd that is a
        parent of the Herdr checkout is deliberately not a match because the
        Herdr root may be a distinct nested worktree.
        """

        target = _root_path(root)
        # Unlike cmux's tool routes, the established status payload has no
        # top-level `ok` member.
        payload = _validate_status(
            self._request("/api/status", require_ok=False)
        )
        workspaces = payload["workspaces"]

        exact: list[tuple[str, int]] = []
        descendants: list[tuple[str, int]] = []
        for workspace in workspaces:
            cwd = workspace.get("cwd")
            if not isinstance(cwd, str) or not cwd or "\x00" in cwd or len(cwd) > 4096:
                continue
            try:
                canonical = Path(cwd).expanduser().resolve()
            except (OSError, RuntimeError, ValueError):
                continue
            if not canonical.is_absolute() or not canonical.is_dir():
                continue
            canonical_text = str(canonical)
            if canonical_text != target:
                try:
                    if os.path.commonpath((target, canonical_text)) != target:
                        continue
                except ValueError:
                    continue

            workspace_uuid = workspace.get("uuid")
            workspace_index = workspace.get("index")
            if (
                not isinstance(workspace_uuid, str)
                or not workspace_uuid.strip()
                or any(character in workspace_uuid for character in ("\x00", "\r", "\n"))
                or not isinstance(workspace_index, int)
                or isinstance(workspace_index, bool)
                or not 0 <= workspace_index <= 2**31 - 1
            ):
                raise CmuxToolsError(
                    "cmux returned an invalid workspace identity",
                    code="cmux_invalid_response",
                    status=502,
                )
            identity = (workspace_uuid.strip(), workspace_index)
            if canonical_text == target:
                exact.append(identity)
            else:
                descendants.append(identity)

        candidates = exact or descendants
        by_uuid: dict[str, list[int]] = {}
        for workspace_uuid, workspace_index in candidates:
            by_uuid.setdefault(workspace_uuid, []).append(workspace_index)
        if not by_uuid:
            raise CmuxToolsError(
                "No live cmux workspace matches this Herdr workspace",
                code="cmux_workspace_not_found",
                status=404,
            )
        if len(by_uuid) != 1:
            raise CmuxToolsError(
                "Multiple live cmux workspaces match this Herdr workspace",
                code="cmux_workspace_ambiguous",
                status=409,
            )
        workspace_uuid, indices = next(iter(by_uuid.items()))
        # The primary surface keeps the real cmux index while additional
        # surfaces use large virtual indices. The smallest index is therefore
        # the stable upload identity for a deduplicated workspace UUID.
        return {"uuid": workspace_uuid, "index": min(indices)}

    def upload_attachment(
        self,
        *,
        workspace_uuid: Optional[str] = None,
        workspace_index: Optional[int] = None,
        filename: str,
        content_type: str,
        data: bytes,
    ) -> dict:
        if not isinstance(data, bytes) or not data:
            raise CmuxToolsError("file is empty", code="invalid_attachment", status=400)
        if len(data) > MAX_ATTACHMENT_BYTES:
            raise CmuxToolsError(
                "file exceeds 20 MB limit",
                code="attachment_too_large",
                status=413,
            )
        if not isinstance(filename, str) or not filename or "\x00" in filename or len(filename) > 512:
            raise CmuxToolsError("filename is invalid", code="invalid_attachment", status=400)
        normalized_type = str(content_type or "application/octet-stream").strip()
        if (
            not normalized_type
            or "\x00" in normalized_type
            or "\r" in normalized_type
            or "\n" in normalized_type
            or len(normalized_type) > 255
        ):
            raise CmuxToolsError("content_type is invalid", code="invalid_attachment", status=400)
        uuid_value = str(workspace_uuid or "").strip()
        if "\r" in uuid_value or "\n" in uuid_value or "\x00" in uuid_value:
            raise CmuxToolsError("workspace is invalid", code="invalid_attachment", status=400)
        if workspace_index is not None and (
            not isinstance(workspace_index, int)
            or isinstance(workspace_index, bool)
            or not 0 <= workspace_index <= 2**31 - 1
        ):
            raise CmuxToolsError(
                "workspace index is invalid",
                code="invalid_attachment",
                status=400,
            )
        index_value = "" if workspace_index is None else str(workspace_index)
        if not uuid_value and not index_value:
            raise CmuxToolsError("workspace is required", code="invalid_attachment", status=400)

        headers = {
            "Content-Type": normalized_type,
            "X-Cmux-Filename": urllib.parse.quote(filename, safe=""),
        }
        if uuid_value:
            headers["X-Cmux-Workspace-UUID"] = uuid_value
        if index_value:
            headers["X-Cmux-Workspace-Index"] = index_value
        return _validate_attachment(
            self._request(
                "/api/attachments",
                data=data,
                headers=headers,
                # Match the original cmux iOS upload contract. Large, bounded
                # attachments get a full minute even when normal API calls use a
                # shorter timeout.
                timeout=self._operation_timeout(ATTACHMENT_TIMEOUT_SECONDS),
            )
        )

    def transcribe_voice(self, *, filename: str, mime_type: str, data: bytes) -> dict:
        if not isinstance(data, bytes) or not data:
            raise CmuxToolsError(
                "recording is empty",
                code="invalid_voice_recording",
                status=400,
            )
        if len(data) > voice.MAX_VOICE_AUDIO_BYTES:
            raise CmuxToolsError(
                "recording exceeds the 20 MB limit",
                code="voice_recording_too_large",
                status=413,
            )
        try:
            voice.validate_voice_wav(data)
        except voice.VoiceError as exc:
            raise CmuxToolsError(
                str(exc),
                code=exc.code,
                status=exc.status,
            ) from exc
        if (
            not isinstance(filename, str)
            or not _VOICE_FILENAME_RE.fullmatch(filename)
        ):
            raise CmuxToolsError(
                "recording filename is invalid",
                code="invalid_voice_recording",
                status=400,
            )
        if mime_type.lower().split(";", 1)[0].strip() not in {
            "audio/wav",
            "audio/x-wav",
            "audio/wave",
        }:
            raise CmuxToolsError(
                "recording must use a WAV content type",
                code="invalid_voice_recording",
                status=400,
            )
        return _validate_transcription(
            self._request(
                "/api/orchestrator-v2/voice/local/transcribe",
                body={
                    "audioBase64": base64.b64encode(data).decode("ascii"),
                    "filename": filename,
                    "mimeType": "audio/wav",
                    "backend": "parakeet",
                    "partial": False,
                    "appendChat": False,
                },
                timeout=self._operation_timeout(VOICE_TIMEOUT_SECONDS),
            )
        )
